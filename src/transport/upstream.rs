//! Upstream Management with per-DC latency-weighted selection

use std::net::{SocketAddr, IpAddr};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::sync::RwLock;
use tokio::time::Instant;
use rand::Rng;
use tracing::{debug, warn, info, trace};

use crate::config::{UpstreamConfig, UpstreamType};
use crate::error::{Result, ProxyError};
use crate::protocol::constants::{TG_DATACENTERS_V4, TG_DATACENTERS_V6, TG_DATACENTER_PORT};
use crate::transport::socket::create_outgoing_socket_bound;
use crate::transport::socks::{connect_socks4, connect_socks5};

/// Number of Telegram datacenters
const NUM_DCS: usize = 5;

// ============= RTT Tracking =============

#[derive(Debug, Clone, Copy)]
struct LatencyEma {
    value_ms: Option<f64>,
    alpha: f64,
}

impl LatencyEma {
    const fn new(alpha: f64) -> Self {
        Self { value_ms: None, alpha }
    }
    
    fn update(&mut self, sample_ms: f64) {
        self.value_ms = Some(match self.value_ms {
            None => sample_ms,
            Some(prev) => prev * (1.0 - self.alpha) + sample_ms * self.alpha,
        });
    }
    
    fn get(&self) -> Option<f64> {
        self.value_ms
    }
}

// ============= Upstream State =============

#[derive(Debug)]
struct UpstreamState {
    config: UpstreamConfig,
    healthy: bool,
    fails: u32,
    last_check: std::time::Instant,
    /// Per-DC latency EMA (index 0 = DC1, index 4 = DC5)
    dc_latency: [LatencyEma; NUM_DCS],
}

impl UpstreamState {
    fn new(config: UpstreamConfig) -> Self {
        Self {
            config,
            healthy: true,
            fails: 0,
            last_check: std::time::Instant::now(),
            dc_latency: [LatencyEma::new(0.3); NUM_DCS],
        }
    }
    
    /// Convert dc_idx (1-based, may be negative) to array index 0..4
    fn dc_array_idx(dc_idx: i16) -> Option<usize> {
        let idx = (dc_idx.unsigned_abs() as usize).checked_sub(1)?;
        if idx < NUM_DCS { Some(idx) } else { None }
    }
    
    /// Get latency for a specific DC, falling back to average across all known DCs
    fn effective_latency(&self, dc_idx: Option<i16>) -> Option<f64> {
        // Try DC-specific latency first
        if let Some(di) = dc_idx.and_then(Self::dc_array_idx) {
            if let Some(ms) = self.dc_latency[di].get() {
                return Some(ms);
            }
        }
        
        // Fallback: average of all known DC latencies
        let (sum, count) = self.dc_latency.iter()
            .filter_map(|l| l.get())
            .fold((0.0, 0u32), |(s, c), v| (s + v, c + 1));
        
        if count > 0 { Some(sum / count as f64) } else { None }
    }
}

/// Result of a single DC ping
#[derive(Debug, Clone)]
pub struct DcPingResult {
    pub dc_idx: usize,
    pub dc_addr: SocketAddr,
    pub rtt_ms: Option<f64>,
    pub error: Option<String>,
}

/// Result of startup ping for one upstream
#[derive(Debug, Clone)]
pub struct StartupPingResult {
    pub results: Vec<DcPingResult>,
    pub upstream_name: String,
}

// ============= Upstream Manager =============

#[derive(Clone)]
pub struct UpstreamManager {
    upstreams: Arc<RwLock<Vec<UpstreamState>>>,
}

impl UpstreamManager {
    pub fn new(configs: Vec<UpstreamConfig>) -> Self {
        let states = configs.into_iter()
            .filter(|c| c.enabled)
            .map(UpstreamState::new)
            .collect();
            
        Self {
            upstreams: Arc::new(RwLock::new(states)),
        }
    }
    
    /// Select upstream using latency-weighted random selection.
    ///
    /// `effective_weight = config_weight × latency_factor`
    ///
    /// where `latency_factor = 1000 / latency_ms` if latency is known,
    /// or `1.0` if no latency data is available.
    ///
    /// This means a 50ms upstream gets factor 20, a 200ms upstream gets
    /// factor 5 — the faster route is 4× more likely to be chosen
    /// (all else being equal).
    async fn select_upstream(&self, dc_idx: Option<i16>) -> Option<usize> {
        let upstreams = self.upstreams.read().await;
        if upstreams.is_empty() {
            return None;
        }

        let healthy: Vec<usize> = upstreams.iter()
            .enumerate()
            .filter(|(_, u)| u.healthy)
            .map(|(i, _)| i)
            .collect();
            
        if healthy.is_empty() {
            // All unhealthy — pick any
            return Some(rand::rng().gen_range(0..upstreams.len()));
        }
        
        if healthy.len() == 1 {
            return Some(healthy[0]);
        }
        
        // Calculate latency-weighted scores
        let weights: Vec<(usize, f64)> = healthy.iter().map(|&i| {
            let base = upstreams[i].config.weight as f64;
            let latency_factor = upstreams[i].effective_latency(dc_idx)
                .map(|ms| if ms > 1.0 { 1000.0 / ms } else { 1000.0 })
                .unwrap_or(1.0);
            
            (i, base * latency_factor)
        }).collect();
        
        let total: f64 = weights.iter().map(|(_, w)| w).sum();
        
        if total <= 0.0 {
            return Some(healthy[rand::rng().gen_range(0..healthy.len())]);
        }
        
        let mut choice: f64 = rand::rng().gen_range(0.0..total);
        
        for &(idx, weight) in &weights {
            if choice < weight {
                trace!(
                    upstream = idx,
                    dc = ?dc_idx,
                    weight = format!("{:.2}", weight),
                    total = format!("{:.2}", total),
                    "Upstream selected"
                );
                return Some(idx);
            }
            choice -= weight;
        }
        
        Some(healthy[0])
    }
    
    /// Connect to target through a selected upstream.
    ///
    /// `dc_idx` is used for latency-based upstream selection and RTT tracking.
    /// Pass `None` if DC index is unknown.
    pub async fn connect(&self, target: SocketAddr, dc_idx: Option<i16>) -> Result<TcpStream> {
        let idx = self.select_upstream(dc_idx).await
            .ok_or_else(|| ProxyError::Config("No upstreams available".to_string()))?;
            
        let upstream = {
            let guard = self.upstreams.read().await;
            guard[idx].config.clone()
        };
        
        let start = Instant::now();
        
        match self.connect_via_upstream(&upstream, target).await {
            Ok(stream) => {
                let rtt_ms = start.elapsed().as_secs_f64() * 1000.0;
                let mut guard = self.upstreams.write().await;
                if let Some(u) = guard.get_mut(idx) {
                    if !u.healthy {
                        debug!(rtt_ms = format!("{:.1}", rtt_ms), "Upstream recovered");
                    }
                    u.healthy = true;
                    u.fails = 0;
                    
                    // Store per-DC latency
                    if let Some(di) = dc_idx.and_then(UpstreamState::dc_array_idx) {
                        u.dc_latency[di].update(rtt_ms);
                    }
                }
                Ok(stream)
            },
            Err(e) => {
                let mut guard = self.upstreams.write().await;
                if let Some(u) = guard.get_mut(idx) {
                    u.fails += 1;
                    warn!(fails = u.fails, "Upstream failed: {}", e);
                    if u.fails > 3 {
                        u.healthy = false;
                        warn!("Upstream marked unhealthy");
                    }
                }
                Err(e)
            }
        }
    }
    
    async fn connect_via_upstream(&self, config: &UpstreamConfig, target: SocketAddr) -> Result<TcpStream> {
        match &config.upstream_type {
            UpstreamType::Direct { interface } => {
                let bind_ip = interface.as_ref()
                    .and_then(|s| s.parse::<IpAddr>().ok());
                
                let socket = create_outgoing_socket_bound(target, bind_ip)?;
                
                socket.set_nonblocking(true)?;
                match socket.connect(&target.into()) {
                    Ok(()) => {},
                    Err(err) if err.raw_os_error() == Some(libc::EINPROGRESS) || err.kind() == std::io::ErrorKind::WouldBlock => {},
                    Err(err) => return Err(ProxyError::Io(err)),
                }
                
                let std_stream: std::net::TcpStream = socket.into();
                let stream = TcpStream::from_std(std_stream)?;
                
                stream.writable().await?;
                if let Some(e) = stream.take_error()? {
                    return Err(ProxyError::Io(e));
                }
                
                Ok(stream)
            },
            UpstreamType::Socks4 { address, interface, user_id } => {
                let proxy_addr: SocketAddr = address.parse()
                    .map_err(|_| ProxyError::Config("Invalid SOCKS4 address".to_string()))?;
                    
                let bind_ip = interface.as_ref()
                    .and_then(|s| s.parse::<IpAddr>().ok());
                
                let socket = create_outgoing_socket_bound(proxy_addr, bind_ip)?;
                
                socket.set_nonblocking(true)?;
                match socket.connect(&proxy_addr.into()) {
                    Ok(()) => {},
                    Err(err) if err.raw_os_error() == Some(libc::EINPROGRESS) || err.kind() == std::io::ErrorKind::WouldBlock => {},
                    Err(err) => return Err(ProxyError::Io(err)),
                }
                
                let std_stream: std::net::TcpStream = socket.into();
                let mut stream = TcpStream::from_std(std_stream)?;
                
                stream.writable().await?;
                if let Some(e) = stream.take_error()? {
                    return Err(ProxyError::Io(e));
                }
                
                connect_socks4(&mut stream, target, user_id.as_deref()).await?;
                Ok(stream)
            },
            UpstreamType::Socks5 { address, interface, username, password } => {
                let proxy_addr: SocketAddr = address.parse()
                    .map_err(|_| ProxyError::Config("Invalid SOCKS5 address".to_string()))?;
                    
                let bind_ip = interface.as_ref()
                    .and_then(|s| s.parse::<IpAddr>().ok());
                
                let socket = create_outgoing_socket_bound(proxy_addr, bind_ip)?;
                
                socket.set_nonblocking(true)?;
                match socket.connect(&proxy_addr.into()) {
                    Ok(()) => {},
                    Err(err) if err.raw_os_error() == Some(libc::EINPROGRESS) || err.kind() == std::io::ErrorKind::WouldBlock => {},
                    Err(err) => return Err(ProxyError::Io(err)),
                }
                
                let std_stream: std::net::TcpStream = socket.into();
                let mut stream = TcpStream::from_std(std_stream)?;
                
                stream.writable().await?;
                if let Some(e) = stream.take_error()? {
                    return Err(ProxyError::Io(e));
                }
                
                connect_socks5(&mut stream, target, username.as_deref(), password.as_deref()).await?;
                Ok(stream)
            },
        }
    }
    
    // ============= Startup Ping =============
    
    /// Ping all Telegram DCs through all upstreams.
    pub async fn ping_all_dcs(&self, prefer_ipv6: bool) -> Vec<StartupPingResult> {
        let upstreams: Vec<(usize, UpstreamConfig)> = {
            let guard = self.upstreams.read().await;
            guard.iter().enumerate()
                .map(|(i, u)| (i, u.config.clone()))
                .collect()
        };
        
        let datacenters = if prefer_ipv6 { &*TG_DATACENTERS_V6 } else { &*TG_DATACENTERS_V4 };
        
        let mut all_results = Vec::new();
        
        for (upstream_idx, upstream_config) in &upstreams {
            let upstream_name = match &upstream_config.upstream_type {
                UpstreamType::Direct { interface } => {
                    format!("direct{}", interface.as_ref().map(|i| format!(" ({})", i)).unwrap_or_default())
                }
                UpstreamType::Socks4 { address, .. } => format!("socks4://{}", address),
                UpstreamType::Socks5 { address, .. } => format!("socks5://{}", address),
            };
            
            let mut dc_results = Vec::new();
            
            for (dc_zero_idx, dc_ip) in datacenters.iter().enumerate() {
                let dc_addr = SocketAddr::new(*dc_ip, TG_DATACENTER_PORT);
                
                let ping_result = tokio::time::timeout(
                    Duration::from_secs(5),
                    self.ping_single_dc(upstream_config, dc_addr)
                ).await;
                
                let result = match ping_result {
                    Ok(Ok(rtt_ms)) => {
                        // Store per-DC latency
                        let mut guard = self.upstreams.write().await;
                        if let Some(u) = guard.get_mut(*upstream_idx) {
                            u.dc_latency[dc_zero_idx].update(rtt_ms);
                        }
                        DcPingResult {
                            dc_idx: dc_zero_idx + 1,
                            dc_addr,
                            rtt_ms: Some(rtt_ms),
                            error: None,
                        }
                    }
                    Ok(Err(e)) => DcPingResult {
                        dc_idx: dc_zero_idx + 1,
                        dc_addr,
                        rtt_ms: None,
                        error: Some(e.to_string()),
                    },
                    Err(_) => DcPingResult {
                        dc_idx: dc_zero_idx + 1,
                        dc_addr,
                        rtt_ms: None,
                        error: Some("timeout (5s)".to_string()),
                    },
                };
                
                dc_results.push(result);
            }
            
            all_results.push(StartupPingResult {
                results: dc_results,
                upstream_name,
            });
        }
        
        all_results
    }
    
    async fn ping_single_dc(&self, config: &UpstreamConfig, target: SocketAddr) -> Result<f64> {
        let start = Instant::now();
        let _stream = self.connect_via_upstream(config, target).await?;
        Ok(start.elapsed().as_secs_f64() * 1000.0)
    }
    
    // ============= Health Checks =============
    
    /// Background health check: rotates through DCs, 30s interval.
    pub async fn run_health_checks(&self, prefer_ipv6: bool) {
        let datacenters = if prefer_ipv6 { &*TG_DATACENTERS_V6 } else { &*TG_DATACENTERS_V4 };
        let mut dc_rotation = 0usize;
        
        loop {
            tokio::time::sleep(Duration::from_secs(30)).await;
            
            let dc_zero_idx = dc_rotation % datacenters.len();
            dc_rotation += 1;
            
            let check_target = SocketAddr::new(datacenters[dc_zero_idx], TG_DATACENTER_PORT);
            
            let count = self.upstreams.read().await.len();
            for i in 0..count {
                let config = {
                    let guard = self.upstreams.read().await;
                    guard[i].config.clone()
                };
                
                let start = Instant::now();
                let result = tokio::time::timeout(
                    Duration::from_secs(10),
                    self.connect_via_upstream(&config, check_target)
                ).await;
                
                let mut guard = self.upstreams.write().await;
                let u = &mut guard[i];
                
                match result {
                    Ok(Ok(_stream)) => {
                        let rtt_ms = start.elapsed().as_secs_f64() * 1000.0;
                        u.dc_latency[dc_zero_idx].update(rtt_ms);
                        
                        if !u.healthy {
                            info!(
                                rtt = format!("{:.0}ms", rtt_ms),
                                dc = dc_zero_idx + 1,
                                "Upstream recovered"
                            );
                        }
                        u.healthy = true;
                        u.fails = 0;
                    }
                    Ok(Err(e)) => {
                        u.fails += 1;
                        debug!(dc = dc_zero_idx + 1, fails = u.fails,
                            "Health check failed: {}", e);
                        if u.fails > 3 {
                            u.healthy = false;
                            warn!("Upstream unhealthy (fails)");
                        }
                    }
                    Err(_) => {
                        u.fails += 1;
                        debug!(dc = dc_zero_idx + 1, fails = u.fails,
                            "Health check timeout");
                        if u.fails > 3 {
                            u.healthy = false;
                            warn!("Upstream unhealthy (timeout)");
                        }
                    }
                }
                u.last_check = std::time::Instant::now();
            }
        }
    }
}