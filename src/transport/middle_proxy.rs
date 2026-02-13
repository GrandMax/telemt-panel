//! Middle Proxy RPC Transport
//!
//! Implements Telegram Middle-End RPC protocol for routing to ALL DCs (including CDN).
//!
//! ## Phase 3 fixes:
//! - ROOT CAUSE: Use Telegram proxy-secret (binary file) not user secret
//! - Streaming handshake response (no fixed-size read deadlock)
//! - Health monitoring + reconnection
//! - Hex diagnostics for debugging

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use bytes::{Bytes, BytesMut};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, Mutex, RwLock};
use tokio::time::{timeout, Instant};
use tracing::{debug, info, trace, warn, error};

use crate::crypto::{crc32, derive_middleproxy_keys, AesCbc, SecureRandom};
use crate::error::{ProxyError, Result};
use crate::protocol::constants::*;

// ========== Proxy Secret Fetching ==========

/// Fetch the Telegram proxy-secret binary file.
///
/// This is NOT the user secret (-S flag, 16 bytes hex for clients).
/// This is the infrastructure secret (--aes-pwd in C MTProxy),
/// a binary file of 32-512 bytes used for ME RPC key derivation.
///
/// Strategy: try local cache, then download from Telegram.
pub async fn fetch_proxy_secret(cache_path: Option<&str>) -> Result<Vec<u8>> {
    let cache = cache_path.unwrap_or("proxy-secret");

    // 1. Try local cache (< 24h old)
    if let Ok(metadata) = tokio::fs::metadata(cache).await {
        if let Ok(modified) = metadata.modified() {
            let age = std::time::SystemTime::now()
                .duration_since(modified)
                .unwrap_or(Duration::from_secs(u64::MAX));
            if age < Duration::from_secs(86400) {
                if let Ok(data) = tokio::fs::read(cache).await {
                    if data.len() >= 32 {
                        info!(
                            path = cache,
                            len = data.len(),
                            age_hours = age.as_secs() / 3600,
                            "Loaded proxy-secret from cache"
                        );
                        return Ok(data);
                    }
                    warn!(path = cache, len = data.len(), "Cached proxy-secret too short");
                }
            }
        }
    }

    // 2. Download from Telegram
    info!("Downloading proxy-secret from core.telegram.org...");
    let data = download_proxy_secret().await?;

    // 3. Cache locally (best-effort)
    if let Err(e) = tokio::fs::write(cache, &data).await {
        warn!(error = %e, "Failed to cache proxy-secret (non-fatal)");
    } else {
        debug!(path = cache, len = data.len(), "Cached proxy-secret");
    }

    Ok(data)
}

async fn download_proxy_secret() -> Result<Vec<u8>> {
    let url = "https://core.telegram.org/getProxySecret";
    let resp = reqwest::get(url)
        .await
        .map_err(|e| ProxyError::Proxy(format!("Failed to download proxy-secret: {}", e)))?;

    if !resp.status().is_success() {
        return Err(ProxyError::Proxy(format!(
            "proxy-secret download HTTP {}", resp.status()
        )));
    }

    let data = resp.bytes().await
        .map_err(|e| ProxyError::Proxy(format!("Read proxy-secret body: {}", e)))?
        .to_vec();

    if data.len() < 32 {
        return Err(ProxyError::Proxy(format!(
            "proxy-secret too short: {} bytes (need >= 32)", data.len()
        )));
    }

    info!(len = data.len(), "Downloaded proxy-secret OK");
    Ok(data)
}

// ========== RPC Frame helpers ==========

/// Build an RPC frame: [len(4) | seq_no(4) | payload | crc32(4)]
fn build_rpc_frame(seq_no: i32, payload: &[u8]) -> Vec<u8> {
    let total_len = (4 + 4 + payload.len() + 4) as u32;
    let mut f = Vec::with_capacity(total_len as usize);
    f.extend_from_slice(&total_len.to_le_bytes());
    f.extend_from_slice(&seq_no.to_le_bytes());
    f.extend_from_slice(payload);
    let c = crc32(&f);
    f.extend_from_slice(&c.to_le_bytes());
    f
}

/// Read one plaintext RPC frame. Returns (seq_no, payload).
async fn read_rpc_frame_plaintext(
    rd: &mut (impl AsyncReadExt + Unpin),
) -> Result<(i32, Vec<u8>)> {
    let mut len_buf = [0u8; 4];
    rd.read_exact(&mut len_buf).await.map_err(ProxyError::Io)?;
    let total_len = u32::from_le_bytes(len_buf) as usize;

    if total_len < 12 || total_len > (1 << 24) {
        return Err(ProxyError::InvalidHandshake(
            format!("Bad RPC frame length: {}", total_len),
        ));
    }

    let mut rest = vec![0u8; total_len - 4];
    rd.read_exact(&mut rest).await.map_err(ProxyError::Io)?;

    let mut full = Vec::with_capacity(total_len);
    full.extend_from_slice(&len_buf);
    full.extend_from_slice(&rest);

    let crc_offset = total_len - 4;
    let expected_crc = u32::from_le_bytes([
        full[crc_offset], full[crc_offset + 1],
        full[crc_offset + 2], full[crc_offset + 3],
    ]);
    let actual_crc = crc32(&full[..crc_offset]);
    if expected_crc != actual_crc {
        return Err(ProxyError::InvalidHandshake(
            format!("CRC mismatch: 0x{:08x} vs 0x{:08x}", expected_crc, actual_crc),
        ));
    }

    let seq_no = i32::from_le_bytes([full[4], full[5], full[6], full[7]]);
    let payload = full[8..crc_offset].to_vec();
    Ok((seq_no, payload))
}

// ========== RPC Nonce (32 bytes payload) ==========

fn build_nonce_payload(key_selector: u32, crypto_ts: u32, nonce: &[u8; 16]) -> [u8; 32] {
    let mut p = [0u8; 32];
    p[0..4].copy_from_slice(&RPC_NONCE_U32.to_le_bytes());
    p[4..8].copy_from_slice(&key_selector.to_le_bytes());
    p[8..12].copy_from_slice(&RPC_CRYPTO_AES_U32.to_le_bytes());
    p[12..16].copy_from_slice(&crypto_ts.to_le_bytes());
    p[16..32].copy_from_slice(nonce);
    p
}

fn parse_nonce_payload(d: &[u8]) -> Result<(u32, u32, [u8; 16])> {
    if d.len() < 32 {
        return Err(ProxyError::InvalidHandshake(
            format!("Nonce payload too short: {} bytes", d.len()),
        ));
    }
    let t = u32::from_le_bytes([d[0], d[1], d[2], d[3]]);
    if t != RPC_NONCE_U32 {
        return Err(ProxyError::InvalidHandshake(
            format!("Expected RPC_NONCE 0x{:08x}, got 0x{:08x}", RPC_NONCE_U32, t),
        ));
    }
    let schema = u32::from_le_bytes([d[8], d[9], d[10], d[11]]);
    let ts = u32::from_le_bytes([d[12], d[13], d[14], d[15]]);
    let mut nonce = [0u8; 16];
    nonce.copy_from_slice(&d[16..32]);
    Ok((schema, ts, nonce))
}

// ========== RPC Handshake (32 bytes payload) ==========

fn build_handshake_payload(our_ip: u32, our_port: u16, peer_ip: u32, peer_port: u16) -> [u8; 32] {
    let mut p = [0u8; 32];
    p[0..4].copy_from_slice(&RPC_HANDSHAKE_U32.to_le_bytes());
    // flags = 0 at offset 4..8

    // sender_pid: {ip(4), port(2), pid(2), utime(4)} at offset 8..20
    p[8..12].copy_from_slice(&our_ip.to_le_bytes());
    p[12..14].copy_from_slice(&our_port.to_le_bytes());
    let pid = (std::process::id() & 0xFFFF) as u16;
    p[14..16].copy_from_slice(&pid.to_le_bytes());
    let utime = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as u32;
    p[16..20].copy_from_slice(&utime.to_le_bytes());

    // peer_pid: {ip(4), port(2), pid(2), utime(4)} at offset 20..32
    p[20..24].copy_from_slice(&peer_ip.to_le_bytes());
    p[24..26].copy_from_slice(&peer_port.to_le_bytes());
    p
}

// ========== CBC helpers ==========

fn cbc_encrypt_padded(key: &[u8; 32], iv: &[u8; 16], plaintext: &[u8]) -> Result<(Vec<u8>, [u8; 16])> {
    let pad = (16 - (plaintext.len() % 16)) % 16;
    let mut buf = plaintext.to_vec();
    let pad_pattern: [u8; 4] = [0x04, 0x00, 0x00, 0x00];
    for i in 0..pad {
        buf.push(pad_pattern[i % 4]);
    }
    let cipher = AesCbc::new(*key, *iv);
    cipher.encrypt_in_place(&mut buf)
        .map_err(|e| ProxyError::Crypto(format!("CBC encrypt: {}", e)))?;
    let mut new_iv = [0u8; 16];
    if buf.len() >= 16 {
        new_iv.copy_from_slice(&buf[buf.len() - 16..]);
    }
    Ok((buf, new_iv))
}

fn cbc_decrypt_inplace(key: &[u8; 32], iv: &[u8; 16], data: &mut [u8]) -> Result<[u8; 16]> {
    let mut new_iv = [0u8; 16];
    if data.len() >= 16 {
        new_iv.copy_from_slice(&data[data.len() - 16..]);
    }
    AesCbc::new(*key, *iv)
        .decrypt_in_place(data)
        .map_err(|e| ProxyError::Crypto(format!("CBC decrypt: {}", e)))?;
    Ok(new_iv)
}

// ========== IPv4 helpers ==========

fn ipv4_to_mapped_v6(ip: Ipv4Addr) -> [u8; 16] {
    let mut buf = [0u8; 16];
    buf[10] = 0xFF;
    buf[11] = 0xFF;
    let o = ip.octets();
    buf[12] = o[0]; buf[13] = o[1]; buf[14] = o[2]; buf[15] = o[3];
    buf
}

fn addr_to_ip_u32(addr: &SocketAddr) -> u32 {
    match addr.ip() {
        IpAddr::V4(v4) => u32::from_be_bytes(v4.octets()),
        IpAddr::V6(_) => 0,
    }
}

// ========== ME Response ==========

#[derive(Debug)]
pub enum MeResponse {
    Data(Bytes),
    Ack(u32),
    Close,
}

// ========== Connection Registry ==========

pub struct ConnRegistry {
    map: RwLock<HashMap<u64, mpsc::Sender<MeResponse>>>,
    next_id: AtomicU64,
}

impl ConnRegistry {
    pub fn new() -> Self {
        Self {
            map: RwLock::new(HashMap::new()),
            next_id: AtomicU64::new(1),
        }
    }
    pub async fn register(&self) -> (u64, mpsc::Receiver<MeResponse>) {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel(256);
        self.map.write().await.insert(id, tx);
        (id, rx)
    }
    pub async fn unregister(&self, id: u64) {
        self.map.write().await.remove(&id);
    }
    pub async fn route(&self, id: u64, resp: MeResponse) -> bool {
        let m = self.map.read().await;
        if let Some(tx) = m.get(&id) {
            tx.send(resp).await.is_ok()
        } else { false }
    }
}

// ========== RPC Writer (streaming CBC) ==========

struct RpcWriter {
    writer: tokio::io::WriteHalf<TcpStream>,
    key: [u8; 32],
    iv: [u8; 16],
    seq_no: i32,
}

impl RpcWriter {
    async fn send(&mut self, payload: &[u8]) -> Result<()> {
        let frame = build_rpc_frame(self.seq_no, payload);
        self.seq_no += 1;

        let pad = (16 - (frame.len() % 16)) % 16;
        let mut buf = frame;
        let pad_pattern: [u8; 4] = [0x04, 0x00, 0x00, 0x00];
        for i in 0..pad {
            buf.push(pad_pattern[i % 4]);
        }

        let cipher = AesCbc::new(self.key, self.iv);
        cipher.encrypt_in_place(&mut buf)
            .map_err(|e| ProxyError::Crypto(format!("{}", e)))?;

        if buf.len() >= 16 {
            self.iv.copy_from_slice(&buf[buf.len() - 16..]);
        }
        self.writer.write_all(&buf).await.map_err(ProxyError::Io)
    }
}

// ========== RPC_PROXY_REQ ==========

fn build_proxy_req_payload(
    conn_id: u64,
    client_addr: SocketAddr,
    our_addr: SocketAddr,
    data: &[u8],
    proxy_tag: Option<&[u8]>,
    proto_flags: u32,
) -> Vec<u8> {
    // proto_flags are provided by caller and must already match C/Erlang transport flags.
    let flags: u32 = proto_flags;

    let mut b = Vec::with_capacity(128 + data.len());
    b.extend_from_slice(&RPC_PROXY_REQ_U32.to_le_bytes());
    b.extend_from_slice(&flags.to_le_bytes());
    b.extend_from_slice(&conn_id.to_le_bytes());

    // Client IP (16 bytes IPv4-mapped-v6) + port (4 bytes)
    match client_addr.ip() {
        IpAddr::V4(v4) => b.extend_from_slice(&ipv4_to_mapped_v6(v4)),
        IpAddr::V6(v6) => b.extend_from_slice(&v6.octets()),
    }
    b.extend_from_slice(&(client_addr.port() as u32).to_le_bytes());

    // Our IP (16 bytes) + port (4 bytes)
    match our_addr.ip() {
        IpAddr::V4(v4) => b.extend_from_slice(&ipv4_to_mapped_v6(v4)),
        IpAddr::V6(v6) => b.extend_from_slice(&v6.octets()),
    }
    b.extend_from_slice(&(our_addr.port() as u32).to_le_bytes());

    // Extra section (proxy_tag)
    if flags & (RPC_FLAG_HAS_AD_TAG | 0x4) != 0 {
        let extra_start = b.len();
        b.extend_from_slice(&0u32.to_le_bytes()); // placeholder

        if let Some(tag) = proxy_tag {
            b.extend_from_slice(&TL_PROXY_TAG_U32.to_le_bytes());
            // TL string encoding
            if tag.len() < 254 {
                b.push(tag.len() as u8);
                b.extend_from_slice(tag);
                let pad = (4 - ((1 + tag.len()) % 4)) % 4;
                b.extend(std::iter::repeat(0u8).take(pad));
            } else {
                b.push(0xfe);
                let len_bytes = (tag.len() as u32).to_le_bytes();
                b.extend_from_slice(&len_bytes[..3]);
                b.extend_from_slice(tag);
                let pad = (4 - (tag.len() % 4)) % 4;
                b.extend(std::iter::repeat(0u8).take(pad));
            }
        }

        let extra_bytes = (b.len() - extra_start - 4) as u32;
        let eb = extra_bytes.to_le_bytes();
        b[extra_start..extra_start + 4].copy_from_slice(&eb);
    }

    b.extend_from_slice(data);
    b
}

// ========== ME Pool ==========

pub struct MePool {
    registry: Arc<ConnRegistry>,
    writers: Arc<RwLock<Vec<Arc<Mutex<RpcWriter>>>>>,
    rr: AtomicU64,
    proxy_tag: Option<Vec<u8>>,
    /// Telegram proxy-secret (binary, 32-512 bytes)
    proxy_secret: Vec<u8>,
    pool_size: usize,
}

impl MePool {
    pub fn new(proxy_tag: Option<Vec<u8>>, proxy_secret: Vec<u8>) -> Arc<Self> {
        Arc::new(Self {
            registry: Arc::new(ConnRegistry::new()),
            writers: Arc::new(RwLock::new(Vec::new())),
            rr: AtomicU64::new(0),
            proxy_tag,
            proxy_secret,
            pool_size: 2,
        })
    }

    pub fn registry(&self) -> &Arc<ConnRegistry> {
        &self.registry
    }

    fn writers_arc(&self) -> Arc<RwLock<Vec<Arc<Mutex<RpcWriter>>>>> {
        self.writers.clone()
    }

    /// key_selector = first 4 bytes of proxy-secret as LE u32
    /// C: main_secret.key_signature via union { char secret[]; int key_signature; }
    fn key_selector(&self) -> u32 {
        if self.proxy_secret.len() >= 4 {
            u32::from_le_bytes([
                self.proxy_secret[0], self.proxy_secret[1],
                self.proxy_secret[2], self.proxy_secret[3],
            ])
        } else { 0 }
    }

    pub async fn init(
        self: &Arc<Self>,
        pool_size: usize,
        rng: &SecureRandom,
    ) -> Result<()> {
        let addrs = &*TG_MIDDLE_PROXIES_FLAT_V4;
        let ks = self.key_selector();
        info!(
            me_servers = addrs.len(),
            pool_size,
            key_selector = format_args!("0x{:08x}", ks),
            secret_len = self.proxy_secret.len(),
            "Initializing ME pool"
        );

        for &(ip, port) in addrs.iter() {
            for i in 0..pool_size {
                let addr = SocketAddr::new(ip, port);
                match self.connect_one(addr, rng).await {
                    Ok(()) => info!(%addr, idx = i, "ME connected"),
                    Err(e) => warn!(%addr, idx = i, error = %e, "ME connect failed"),
                }
            }
            if self.writers.read().await.len() >= pool_size {
                break;
            }
        }

        if self.writers.read().await.is_empty() {
            return Err(ProxyError::Proxy("No ME connections".into()));
        }
        Ok(())
    }

    async fn connect_one(
        self: &Arc<Self>,
        addr: SocketAddr,
        rng: &SecureRandom,
    ) -> Result<()> {
        let secret = &self.proxy_secret;
        if secret.len() < 32 {
            return Err(ProxyError::Proxy("proxy-secret too short for ME auth".into()));
        }

        // ===== TCP connect =====
        let stream = timeout(
            Duration::from_secs(ME_CONNECT_TIMEOUT_SECS),
            TcpStream::connect(addr),
        )
        .await
        .map_err(|_| ProxyError::ConnectionTimeout { addr: addr.to_string() })?
        .map_err(ProxyError::Io)?;
        stream.set_nodelay(true).ok();

        let local_addr = stream.local_addr().map_err(ProxyError::Io)?;
        let peer_addr = stream.peer_addr().map_err(ProxyError::Io)?;
        let (mut rd, mut wr) = tokio::io::split(stream);

        // ===== 1. Send RPC nonce (plaintext, seq=-2) =====
        let my_nonce: [u8; 16] = rng.bytes(16).try_into().unwrap();
        let crypto_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as u32;
        let ks = self.key_selector();

        let nonce_payload = build_nonce_payload(ks, crypto_ts, &my_nonce);
        let nonce_frame = build_rpc_frame(-2, &nonce_payload);

        debug!(
            %addr,
            frame_len = nonce_frame.len(),
            key_sel = format_args!("0x{:08x}", ks),
            crypto_ts,
            "Sending nonce"
        );

        wr.write_all(&nonce_frame).await.map_err(ProxyError::Io)?;
        wr.flush().await.map_err(ProxyError::Io)?;

        // ===== 2. Read server nonce (plaintext, seq=-2) =====
        let (srv_seq, srv_nonce_payload) = timeout(
            Duration::from_secs(ME_HANDSHAKE_TIMEOUT_SECS),
            read_rpc_frame_plaintext(&mut rd),
        )
        .await
        .map_err(|_| ProxyError::TgHandshakeTimeout)??;

        if srv_seq != -2 {
            return Err(ProxyError::InvalidHandshake(
                format!("Expected seq=-2, got {}", srv_seq),
            ));
        }

        let (schema, _srv_ts, srv_nonce) = parse_nonce_payload(&srv_nonce_payload)?;
        if schema != RPC_CRYPTO_AES_U32 {
            return Err(ProxyError::InvalidHandshake(
                format!("Unsupported crypto schema: 0x{:x}", schema),
            ));
        }

        debug!(%addr, "Nonce exchange OK, deriving keys");

        // ===== 3. Derive AES-256-CBC keys =====
        // C buffer layout:
        //   [0..16]  nonce_server (srv_nonce)
        //   [16..32] nonce_client (my_nonce)
        //   [32..36] client_timestamp
        //   [36..40] server_ip
        //   [40..42] client_port
        //   [42..48] "CLIENT" or "SERVER"
        //   [48..52] client_ip
        //   [52..54] server_port
        //   [54..54+N] secret (proxy-secret binary)
        //   [54+N..70+N] nonce_server
        //   nonce_client(16)

        let ts_bytes = crypto_ts.to_le_bytes();
        let server_ip = addr_to_ip_u32(&peer_addr);
        let client_ip = addr_to_ip_u32(&local_addr);
        let server_ip_bytes = server_ip.to_le_bytes();
        let client_ip_bytes = client_ip.to_le_bytes();
        let server_port_bytes = peer_addr.port().to_le_bytes();
        let client_port_bytes = local_addr.port().to_le_bytes();

        let (wk, wi) = derive_middleproxy_keys(
            &srv_nonce, &my_nonce, &ts_bytes,
            Some(&server_ip_bytes), &client_port_bytes,
            b"CLIENT",
            Some(&client_ip_bytes), &server_port_bytes,
            secret, None, None,
        );
        let (rk, ri) = derive_middleproxy_keys(
            &srv_nonce, &my_nonce, &ts_bytes,
            Some(&server_ip_bytes), &client_port_bytes,
            b"SERVER",
            Some(&client_ip_bytes), &server_port_bytes,
            secret, None, None,
        );

        debug!(
            %addr,
            write_key = %hex::encode(&wk[..8]),
            read_key = %hex::encode(&rk[..8]),
            "Keys derived"
        );

        // ===== 4. Send encrypted handshake (seq=-1) =====
        let hs_payload = build_handshake_payload(
            client_ip, local_addr.port(),
            server_ip, peer_addr.port(),
        );
        let hs_frame = build_rpc_frame(-1, &hs_payload);
        let (encrypted_hs, write_iv) = cbc_encrypt_padded(&wk, &wi, &hs_frame)?;
        wr.write_all(&encrypted_hs).await.map_err(ProxyError::Io)?;
        wr.flush().await.map_err(ProxyError::Io)?;

        debug!(%addr, enc_len = encrypted_hs.len(), "Sent encrypted handshake");

        // ===== 5. Read encrypted handshake response (STREAMING) =====
        // Server sends encrypted handshake. C crypto layer may send partial
        // blocks (only complete 16-byte blocks get encrypted at a time).
        // We read incrementally and decrypt block-by-block.
        let deadline = Instant::now() + Duration::from_secs(ME_HANDSHAKE_TIMEOUT_SECS);
        let mut enc_buf = BytesMut::with_capacity(256);
        let mut dec_buf = BytesMut::with_capacity(256);
        let mut read_iv = ri;
        let mut handshake_ok = false;

        while Instant::now() < deadline && !handshake_ok {
            let remaining = deadline - Instant::now();
            let mut tmp = [0u8; 256];
            let n = match timeout(remaining, rd.read(&mut tmp)).await {
                Ok(Ok(0)) => return Err(ProxyError::Io(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof, "ME closed during handshake",
                ))),
                Ok(Ok(n)) => n,
                Ok(Err(e)) => return Err(ProxyError::Io(e)),
                Err(_) => return Err(ProxyError::TgHandshakeTimeout),
            };
            enc_buf.extend_from_slice(&tmp[..n]);

            // Decrypt complete 16-byte blocks
            let blocks = enc_buf.len() / 16 * 16;
            if blocks > 0 {
                let mut chunk = vec![0u8; blocks];
                chunk.copy_from_slice(&enc_buf[..blocks]);
                let new_iv = cbc_decrypt_inplace(&rk, &read_iv, &mut chunk)?;
                read_iv = new_iv;
                dec_buf.extend_from_slice(&chunk);
                let _ = enc_buf.split_to(blocks);
            }

            // Try to parse RPC frame from decrypted data
            while dec_buf.len() >= 4 {
                let fl = u32::from_le_bytes([
                    dec_buf[0], dec_buf[1], dec_buf[2], dec_buf[3],
                ]) as usize;

                // Skip noop padding
                if fl == 4 {
                    let _ = dec_buf.split_to(4);
                    continue;
                }
                if fl < 12 || fl > (1 << 24) {
                    return Err(ProxyError::InvalidHandshake(
                        format!("Bad HS response frame len: {}", fl),
                    ));
                }
                if dec_buf.len() < fl {
                    break; // need more data
                }

                let frame = dec_buf.split_to(fl);

                // CRC32 check
                let pe = fl - 4;
                let ec = u32::from_le_bytes([
                    frame[pe], frame[pe + 1], frame[pe + 2], frame[pe + 3],
                ]);
                let ac = crc32(&frame[..pe]);
                if ec != ac {
                    return Err(ProxyError::InvalidHandshake(
                        format!("HS CRC mismatch: 0x{:08x} vs 0x{:08x}", ec, ac),
                    ));
                }

                // Check type
                let hs_type = u32::from_le_bytes([
                    frame[8], frame[9], frame[10], frame[11],
                ]);
                if hs_type == RPC_HANDSHAKE_ERROR_U32 {
                    let err_code = if frame.len() >= 16 {
                        i32::from_le_bytes([frame[12], frame[13], frame[14], frame[15]])
                    } else { -1 };
                    return Err(ProxyError::InvalidHandshake(
                        format!("ME rejected handshake (error={})", err_code),
                    ));
                }
                if hs_type != RPC_HANDSHAKE_U32 {
                    return Err(ProxyError::InvalidHandshake(
                        format!("Expected HANDSHAKE 0x{:08x}, got 0x{:08x}", RPC_HANDSHAKE_U32, hs_type),
                    ));
                }

                handshake_ok = true;
                break;
            }
        }

        if !handshake_ok {
            return Err(ProxyError::TgHandshakeTimeout);
        }

        info!(%addr, "RPC handshake OK");

        // ===== 6. Setup writer + reader =====
        let rpc_w = Arc::new(Mutex::new(RpcWriter {
            writer: wr,
            key: wk,
            iv: write_iv,
            seq_no: 0,
        }));
        self.writers.write().await.push(rpc_w.clone());

        let reg = self.registry.clone();
        let w_pong = rpc_w.clone();
        let w_pool = self.writers_arc();
        tokio::spawn(async move {
            if let Err(e) = reader_loop(rd, rk, read_iv, reg, enc_buf, dec_buf, w_pong.clone()).await {
                warn!(error = %e, "ME reader ended");
            }
            // Remove dead writer from pool
            let mut ws = w_pool.write().await;
            ws.retain(|w| !Arc::ptr_eq(w, &w_pong));
            info!(remaining = ws.len(), "Dead ME writer removed from pool");
        });

        Ok(())
    }

    pub async fn send_proxy_req(
        &self,
        conn_id: u64,
        client_addr: SocketAddr,
        our_addr: SocketAddr,
        data: &[u8],
        proto_flags: u32,
    ) -> Result<()> {
        let payload = build_proxy_req_payload(
            conn_id, client_addr, our_addr, data,
            self.proxy_tag.as_deref(), proto_flags,
        );
        loop {
            let ws = self.writers.read().await;
            if ws.is_empty() {
                return Err(ProxyError::Proxy("All ME connections dead".into()));
            }
            let idx = self.rr.fetch_add(1, Ordering::Relaxed) as usize % ws.len();
            let w = ws[idx].clone();
            drop(ws);
            match w.lock().await.send(&payload).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    warn!(error = %e, "ME write failed, removing dead conn");
                    let mut ws = self.writers.write().await;
                    ws.retain(|o| !Arc::ptr_eq(o, &w));
                    if ws.is_empty() {
                        return Err(ProxyError::Proxy("All ME connections dead".into()));
                    }
                }
            }
        }
    }

    pub async fn send_close(&self, conn_id: u64) -> Result<()> {
        let ws = self.writers.read().await;
        if !ws.is_empty() {
            let w = ws[0].clone();
            drop(ws);
            let mut p = Vec::with_capacity(12);
            p.extend_from_slice(&RPC_CLOSE_EXT_U32.to_le_bytes());
            p.extend_from_slice(&conn_id.to_le_bytes());
            if let Err(e) = w.lock().await.send(&p).await {
                debug!(error = %e, "ME close write failed");
                let mut ws = self.writers.write().await;
                ws.retain(|o| !Arc::ptr_eq(o, &w));
            }
        }
        self.registry.unregister(conn_id).await;
        Ok(())
    }

    pub fn connection_count(&self) -> usize {
        self.writers.try_read().map(|w| w.len()).unwrap_or(0)
    }
}

// ========== Reader Loop ==========

async fn reader_loop(
    mut rd: tokio::io::ReadHalf<TcpStream>,
    dk: [u8; 32],
    mut div: [u8; 16],
    reg: Arc<ConnRegistry>,
    mut enc_leftover: BytesMut,
    mut dec: BytesMut,
    writer: Arc<Mutex<RpcWriter>>,
) -> Result<()> {
    let mut raw = enc_leftover;
    loop {
        let mut tmp = [0u8; 16384];
        let n = rd.read(&mut tmp).await.map_err(ProxyError::Io)?;
        if n == 0 { return Ok(()); }
        raw.extend_from_slice(&tmp[..n]);

        // Decrypt complete 16-byte blocks
        let blocks = raw.len() / 16 * 16;
        if blocks > 0 {
            let mut new_iv = [0u8; 16];
            new_iv.copy_from_slice(&raw[blocks - 16..blocks]);
            let mut chunk = vec![0u8; blocks];
            chunk.copy_from_slice(&raw[..blocks]);
            AesCbc::new(dk, div)
                .decrypt_in_place(&mut chunk)
                .map_err(|e| ProxyError::Crypto(format!("{}", e)))?;
            div = new_iv;
            dec.extend_from_slice(&chunk);
            let _ = raw.split_to(blocks);
        }

        // Parse RPC frames
        while dec.len() >= 12 {
            let fl = u32::from_le_bytes([dec[0], dec[1], dec[2], dec[3]]) as usize;
            if fl == 4 { let _ = dec.split_to(4); continue; }
            if fl < 12 || fl > (1 << 24) {
                warn!(frame_len = fl, "Invalid RPC frame len");
                dec.clear();
                break;
            }
            if dec.len() < fl { break; }

            let frame = dec.split_to(fl);
            let pe = fl - 4;
            let ec = u32::from_le_bytes([frame[pe], frame[pe+1], frame[pe+2], frame[pe+3]]);
            if crc32(&frame[..pe]) != ec {
                warn!("CRC mismatch in data frame");
                continue;
            }

            let payload = &frame[8..pe];
            if payload.len() < 4 { continue; }
            let pt = u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]);
            let body = &payload[4..];

            if pt == RPC_PROXY_ANS_U32 && body.len() >= 12 {
                let flags = u32::from_le_bytes(body[0..4].try_into().unwrap());
                let cid = u64::from_le_bytes(body[4..12].try_into().unwrap());
                let data = Bytes::copy_from_slice(&body[12..]);
                trace!(cid, len = data.len(), flags, "ANS");
                reg.route(cid, MeResponse::Data(data)).await;
            } else if pt == RPC_SIMPLE_ACK_U32 && body.len() >= 12 {
                let cid = u64::from_le_bytes(body[0..8].try_into().unwrap());
                let cfm = u32::from_le_bytes(body[8..12].try_into().unwrap());
                trace!(cid, cfm, "ACK");
                reg.route(cid, MeResponse::Ack(cfm)).await;
            } else if pt == RPC_CLOSE_EXT_U32 && body.len() >= 8 {
                let cid = u64::from_le_bytes(body[0..8].try_into().unwrap());
                debug!(cid, "CLOSE_EXT from ME");
                reg.route(cid, MeResponse::Close).await;
                reg.unregister(cid).await;
            } else if pt == RPC_CLOSE_CONN_U32 && body.len() >= 8 {
                let cid = u64::from_le_bytes(body[0..8].try_into().unwrap());
                debug!(cid, "CLOSE_CONN from ME");
                reg.route(cid, MeResponse::Close).await;
                reg.unregister(cid).await;
            } else if pt == RPC_PING_U32 && body.len() >= 8 {
                let ping_id = i64::from_le_bytes(body[0..8].try_into().unwrap());
                trace!(ping_id, "RPC_PING -> PONG");
                let mut pong = Vec::with_capacity(12);
                pong.extend_from_slice(&RPC_PONG_U32.to_le_bytes());
                pong.extend_from_slice(&ping_id.to_le_bytes());
                if let Err(e) = writer.lock().await.send(&pong).await {
                    warn!(error = %e, "PONG send failed");
                    break;
                }
            } else {
                debug!(rpc_type = format_args!("0x{:08x}", pt), len = body.len(), "Unknown RPC");
            }
        }
    }
}

// ========== Proto flags ==========

/// Map ProtoTag to C-compatible RPC_PROXY_REQ transport flags.
/// Returned value already includes ad_tag/magic/extmode2.
pub fn proto_flags_for_tag(proto_tag: Option<u32>) -> u32 {
    let mut flags = RPC_FLAG_HAS_AD_TAG | RPC_FLAG_MAGIC | RPC_FLAG_EXTMODE2;
    match proto_tag {
        Some(0xdddddddd) => {
            // Secure
            flags |= RPC_FLAG_PAD | RPC_FLAG_INTERMEDIATE;
        }
        Some(0xeeeeeeee) => {
            // Intermediate
            flags |= RPC_FLAG_INTERMEDIATE;
        }
        Some(0xefefefef) => {
            // Abridged
            flags |= RPC_FLAG_ABRIDGED;
        }
        _ => {
            flags |= RPC_FLAG_INTERMEDIATE;
        }
    }
    flags
}

#[cfg(test)]
mod tests {
    use super::proto_flags_for_tag;

    #[test]
    fn proto_flags_secure_matches_reference() {
        assert_eq!(proto_flags_for_tag(Some(0xdddddddd)), 0x28021008);
    }

    #[test]
    fn proto_flags_intermediate_matches_reference() {
        assert_eq!(proto_flags_for_tag(Some(0xeeeeeeee)), 0x20021008);
    }
}

// ========== Health Monitor (Phase 4) ==========

pub async fn me_health_monitor(
    pool: Arc<MePool>,
    rng: Arc<SecureRandom>,
    min_connections: usize,
) {
    loop {
        tokio::time::sleep(Duration::from_secs(30)).await;
        let current = pool.writers.read().await.len();
        if current < min_connections {
            warn!(current, min = min_connections, "ME pool below minimum, reconnecting...");
            let addrs = TG_MIDDLE_PROXIES_FLAT_V4.clone();
            for &(ip, port) in addrs.iter() {
                let needed = min_connections.saturating_sub(pool.writers.read().await.len());
                if needed == 0 { break; }
                for _ in 0..needed {
                    let addr = SocketAddr::new(ip, port);
                    match pool.connect_one(addr, &rng).await {
                        Ok(()) => info!(%addr, "ME reconnected"),
                        Err(e) => debug!(%addr, error = %e, "ME reconnect failed"),
                    }
                }
            }
        }
    }
}
