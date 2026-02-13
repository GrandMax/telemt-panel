//! Client Handler
    
    use std::net::SocketAddr;
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::net::TcpStream;
    use tokio::io::{AsyncRead, AsyncWrite, AsyncReadExt, AsyncWriteExt};
    use tokio::time::timeout;
    use tracing::{debug, info, warn, error, trace};
    
    use crate::config::ProxyConfig;
    use crate::error::{ProxyError, Result, HandshakeResult};
    use crate::protocol::constants::*;
    use crate::protocol::tls;
    use crate::stats::{Stats, ReplayChecker};
    use crate::transport::{configure_client_socket, UpstreamManager};
    use crate::transport::middle_proxy::{MePool, MeResponse};
    use crate::stream::{CryptoReader, CryptoWriter, FakeTlsReader, FakeTlsWriter, BufferPool};
    use crate::crypto::{AesCtr, SecureRandom};
    
    use crate::proxy::handshake::{
        handle_tls_handshake, handle_mtproto_handshake, 
        HandshakeSuccess, generate_tg_nonce, encrypt_tg_nonce,
    };
    use crate::proxy::relay::relay_bidirectional;
    use crate::proxy::masking::handle_bad_client;
    
    pub struct ClientHandler;
    
    pub struct RunningClientHandler {
        stream: TcpStream,
        peer: SocketAddr,
        config: Arc<ProxyConfig>,
        stats: Arc<Stats>,
        replay_checker: Arc<ReplayChecker>,
        upstream_manager: Arc<UpstreamManager>,
        buffer_pool: Arc<BufferPool>,
        rng: Arc<SecureRandom>,
        me_pool: Option<Arc<MePool>>,
    }
    
    impl ClientHandler {
        pub fn new(
            stream: TcpStream,
            peer: SocketAddr,
            config: Arc<ProxyConfig>,
            stats: Arc<Stats>,
            upstream_manager: Arc<UpstreamManager>,
            replay_checker: Arc<ReplayChecker>,
            buffer_pool: Arc<BufferPool>,
            rng: Arc<SecureRandom>,
            me_pool: Option<Arc<MePool>>,
        ) -> RunningClientHandler {
            RunningClientHandler {
                stream, peer, config, stats, replay_checker,
                upstream_manager, buffer_pool, rng, me_pool,
            }
        }
    }
    
    impl RunningClientHandler {
        pub async fn run(mut self) -> Result<()> {
            self.stats.increment_connects_all();
    
            let peer = self.peer;
            debug!(peer = %peer, "New connection");
    
            if let Err(e) = configure_client_socket(
                &self.stream,
                self.config.timeouts.client_keepalive,
                self.config.timeouts.client_ack,
            ) {
                debug!(peer = %peer, error = %e, "Failed to configure client socket");
            }
    
            let handshake_timeout = Duration::from_secs(self.config.timeouts.client_handshake);
            let stats = self.stats.clone();
    
            let result = timeout(handshake_timeout, self.do_handshake()).await;
    
            match result {
                Ok(Ok(())) => {
                    debug!(peer = %peer, "Connection handled successfully");
                    Ok(())
                }
                Ok(Err(e)) => {
                    debug!(peer = %peer, error = %e, "Handshake failed");
                    Err(e)
                }
                Err(_) => {
                    stats.increment_handshake_timeouts();
                    debug!(peer = %peer, "Handshake timeout");
                    Err(ProxyError::TgHandshakeTimeout)
                }
            }
        }
    
        async fn do_handshake(mut self) -> Result<()> {
            let mut first_bytes = [0u8; 5];
            self.stream.read_exact(&mut first_bytes).await?;
    
            let is_tls = tls::is_tls_handshake(&first_bytes[..3]);
            let peer = self.peer;
    
            debug!(peer = %peer, is_tls = is_tls, "Handshake type detected");
    
            if is_tls {
                self.handle_tls_client(first_bytes).await
            } else {
                self.handle_direct_client(first_bytes).await
            }
        }
    
        async fn handle_tls_client(mut self, first_bytes: [u8; 5]) -> Result<()> {
            let peer = self.peer;
    
            let tls_len = u16::from_be_bytes([first_bytes[3], first_bytes[4]]) as usize;
    
            debug!(peer = %peer, tls_len = tls_len, "Reading TLS handshake");
    
            if tls_len < 512 {
                debug!(peer = %peer, tls_len = tls_len, "TLS handshake too short");
                self.stats.increment_connects_bad();
                let (reader, writer) = self.stream.into_split();
                handle_bad_client(reader, writer, &first_bytes, &self.config).await;
                return Ok(());
            }
    
            let mut handshake = vec![0u8; 5 + tls_len];
            handshake[..5].copy_from_slice(&first_bytes);
            self.stream.read_exact(&mut handshake[5..]).await?;
    
            let config = self.config.clone();
            let replay_checker = self.replay_checker.clone();
            let stats = self.stats.clone();
            let buffer_pool = self.buffer_pool.clone();
    
            let (read_half, write_half) = self.stream.into_split();
    
            let (mut tls_reader, tls_writer, _tls_user) = match handle_tls_handshake(
                &handshake, read_half, write_half, peer,
                &config, &replay_checker, &self.rng,
            ).await {
                HandshakeResult::Success(result) => result,
                HandshakeResult::BadClient { reader, writer } => {
                    stats.increment_connects_bad();
                    handle_bad_client(reader, writer, &handshake, &config).await;
                    return Ok(());
                }
                HandshakeResult::Error(e) => return Err(e),
            };
    
            debug!(peer = %peer, "Reading MTProto handshake through TLS");
            let mtproto_data = tls_reader.read_exact(HANDSHAKE_LEN).await?;
            let mtproto_handshake: [u8; HANDSHAKE_LEN] = mtproto_data[..].try_into()
                .map_err(|_| ProxyError::InvalidHandshake("Short MTProto handshake".into()))?;
    
            let (crypto_reader, crypto_writer, success) = match handle_mtproto_handshake(
                &mtproto_handshake, tls_reader, tls_writer, peer,
                &config, &replay_checker, true,
            ).await {
                HandshakeResult::Success(result) => result,
                HandshakeResult::BadClient { reader: _, writer: _ } => {
                    stats.increment_connects_bad();
                    debug!(peer = %peer, "Valid TLS but invalid MTProto handshake");
                    return Ok(());
                }
                HandshakeResult::Error(e) => return Err(e),
            };
    
            Self::handle_authenticated_static(
                crypto_reader, crypto_writer, success,
                self.upstream_manager, self.stats, self.config,
                buffer_pool, self.rng, self.me_pool,
            ).await
        }
    
        async fn handle_direct_client(mut self, first_bytes: [u8; 5]) -> Result<()> {
            let peer = self.peer;
    
            if !self.config.general.modes.classic && !self.config.general.modes.secure {
                debug!(peer = %peer, "Non-TLS modes disabled");
                self.stats.increment_connects_bad();
                let (reader, writer) = self.stream.into_split();
                handle_bad_client(reader, writer, &first_bytes, &self.config).await;
                return Ok(());
            }
    
            let mut handshake = [0u8; HANDSHAKE_LEN];
            handshake[..5].copy_from_slice(&first_bytes);
            self.stream.read_exact(&mut handshake[5..]).await?;
    
            let config = self.config.clone();
            let replay_checker = self.replay_checker.clone();
            let stats = self.stats.clone();
            let buffer_pool = self.buffer_pool.clone();
    
            let (read_half, write_half) = self.stream.into_split();
    
            let (crypto_reader, crypto_writer, success) = match handle_mtproto_handshake(
                &handshake, read_half, write_half, peer,
                &config, &replay_checker, false,
            ).await {
                HandshakeResult::Success(result) => result,
                HandshakeResult::BadClient { reader, writer } => {
                    stats.increment_connects_bad();
                    handle_bad_client(reader, writer, &handshake, &config).await;
                    return Ok(());
                }
                HandshakeResult::Error(e) => return Err(e),
            };
    
            Self::handle_authenticated_static(
                crypto_reader, crypto_writer, success,
                self.upstream_manager, self.stats, self.config,
                buffer_pool, self.rng, self.me_pool,
            ).await
        }
    
        /// Main dispatch after successful handshake.
        /// Two modes:
        ///   - Direct: TCP relay to TG DC (existing behavior)  
        ///   - Middle Proxy: RPC multiplex through ME pool (new — supports CDN DCs)
        async fn handle_authenticated_static<R, W>(
            client_reader: CryptoReader<R>,
            client_writer: CryptoWriter<W>,
            success: HandshakeSuccess,
            upstream_manager: Arc<UpstreamManager>,
            stats: Arc<Stats>,
            config: Arc<ProxyConfig>,
            buffer_pool: Arc<BufferPool>,
            rng: Arc<SecureRandom>,
            me_pool: Option<Arc<MePool>>,
        ) -> Result<()>
        where
            R: AsyncRead + Unpin + Send + 'static,
            W: AsyncWrite + Unpin + Send + 'static,
        {
            let user = &success.user;
    
            if let Err(e) = Self::check_user_limits_static(user, &config, &stats) {
                warn!(user = %user, error = %e, "User limit exceeded");
                return Err(e);
            }
    
            // Decide: middle proxy or direct
            if config.general.use_middle_proxy {
                if let Some(ref pool) = me_pool {
                    return Self::handle_via_middle_proxy(
                        client_reader, client_writer, success,
                        pool.clone(), stats, config, buffer_pool,
                    ).await;
                }
                warn!("use_middle_proxy=true but MePool not initialized, falling back to direct");
            }
    
            // Direct mode (original behavior)
            Self::handle_via_direct(
                client_reader, client_writer, success,
                upstream_manager, stats, config, buffer_pool, rng,
            ).await
        }
    
        // =====================================================================
        // Direct mode — TCP relay to Telegram DC
        // =====================================================================
    
        async fn handle_via_direct<R, W>(
            client_reader: CryptoReader<R>,
            client_writer: CryptoWriter<W>,
            success: HandshakeSuccess,
            upstream_manager: Arc<UpstreamManager>,
            stats: Arc<Stats>,
            config: Arc<ProxyConfig>,
            buffer_pool: Arc<BufferPool>,
            rng: Arc<SecureRandom>,
        ) -> Result<()>
        where
            R: AsyncRead + Unpin + Send + 'static,
            W: AsyncWrite + Unpin + Send + 'static,
        {
            let user = &success.user;
            let dc_addr = Self::get_dc_addr_static(success.dc_idx, &config)?;
    
            info!(
                user = %user,
                peer = %success.peer,
                dc = success.dc_idx,
                dc_addr = %dc_addr,
                proto = ?success.proto_tag,
                mode = "direct",
                "Connecting to Telegram DC"
            );
    
            let tg_stream = upstream_manager.connect(dc_addr, Some(success.dc_idx)).await?;
    
            debug!(peer = %success.peer, dc_addr = %dc_addr, "Connected, performing TG handshake");
    
            let (tg_reader, tg_writer) = Self::do_tg_handshake_static(
                tg_stream, &success, &config, rng.as_ref(),
            ).await?;
    
            debug!(peer = %success.peer, "TG handshake complete, starting relay");
    
            stats.increment_user_connects(user);
            stats.increment_user_curr_connects(user);
    
            let relay_result = relay_bidirectional(
                client_reader, client_writer,
                tg_reader, tg_writer,
                user, Arc::clone(&stats), buffer_pool,
            ).await;
    
            stats.decrement_user_curr_connects(user);
    
            match &relay_result {
                Ok(()) => debug!(user = %user, "Direct relay completed"),
                Err(e) => debug!(user = %user, error = %e, "Direct relay ended with error"),
            }
    
            relay_result
        }
    
        // =====================================================================
        // Middle Proxy mode — RPC multiplex through ME pool
        // =====================================================================
    
        /// Middle Proxy RPC relay
        ///
        /// Architecture (matches C MTProxy):
        /// ```text
        ///   Client ←AES-CTR→ [telemt] ←RPC/AES-CBC→ ME ←internal→ DC (any, incl CDN 203)
        /// ```
        ///
        /// Key difference from direct mode:
        /// - No per-client TCP to DC; all clients share ME pool connections
        /// - ME internally routes to correct DC based on client's encrypted auth_key_id
        /// - CDN DCs (203+) work because ME knows their internal addresses
        /// - We pass raw client MTProto bytes in RPC_PROXY_REQ envelope
        /// - ME returns responses in RPC_PROXY_ANS envelope
        async fn handle_via_middle_proxy<R, W>(
            mut client_reader: CryptoReader<R>,
            mut client_writer: CryptoWriter<W>,
            success: HandshakeSuccess,
            me_pool: Arc<MePool>,
            stats: Arc<Stats>,
            config: Arc<ProxyConfig>,
            _buffer_pool: Arc<BufferPool>,
        ) -> Result<()>
        where
            R: AsyncRead + Unpin + Send + 'static,
            W: AsyncWrite + Unpin + Send + 'static,
        {
            let user = success.user.clone();
            let peer = success.peer;
    
            info!(
                user = %user,
                peer = %peer,
                dc = success.dc_idx,
                proto = ?success.proto_tag,
                mode = "middle_proxy",
                "Routing via Middle-End"
            );
    
            // Register this client connection in ME demux registry
            let (conn_id, mut me_rx) = me_pool.registry().register().await;
    
            // Our listening address for RPC_PROXY_REQ metadata
            let our_addr: SocketAddr = format!("0.0.0.0:{}", config.server.port)
                .parse().unwrap_or_else(|_| "0.0.0.0:443".parse().unwrap());
    
            stats.increment_user_connects(&user);
            stats.increment_user_curr_connects(&user);
    
            debug!(user = %user, conn_id, "ME relay started");
    
            // Bidirectional relay loop: client ↔ ME pool
            //
            // C→S direction: read raw bytes from client_reader, wrap in RPC_PROXY_REQ, send via ME
            // S→C direction: receive MeResponse::Data from registry channel, write to client_writer
            //
            // We use tokio::select! to handle both directions concurrently.
            // Unlike direct mode (copy_bidirectional on two TCP streams),
            // here one side is a channel (mpsc::Receiver), not a stream.
    
            let mut client_buf = vec![0u8; 64 * 1024];
            let mut client_closed = false;
            let mut server_closed = false;
    
            let result: Result<()> = loop {
                tokio::select! {
                    // C→S: client sends data, we forward to ME
                    read_result = client_reader.read(&mut client_buf), if !client_closed => {
                        match read_result {
                            Ok(0) => {
                                debug!(conn_id, "Client EOF");
                                client_closed = true;
                                if server_closed { break Ok(()); }
                                // Signal ME to close this connection
                                let _ = me_pool.send_close(conn_id).await;
                            }
                            Ok(n) => {
                                trace!(conn_id, bytes = n, "C→ME");
                                stats.add_user_octets_from(&user, n as u64);
                                if let Err(e) = me_pool.send_proxy_req(
                                    conn_id, peer, our_addr, &client_buf[..n]
                                ).await {
                                    break Err(e);
                                }
                            }
                            Err(e) => {
                                debug!(conn_id, error = %e, "Client read error");
                                break Err(ProxyError::Io(e));
                            }
                        }
                    }
    
                    // S→C: ME sends response, we forward to client
                    me_msg = me_rx.recv(), if !server_closed => {
                        match me_msg {
                            Some(MeResponse::Data(data)) => {
                                trace!(conn_id, bytes = data.len(), "ME→C");
                                stats.add_user_octets_to(&user, data.len() as u64);
                                if let Err(e) = client_writer.write_all(&data).await {
                                    debug!(conn_id, error = %e, "Client write error");
                                    break Err(ProxyError::Io(e));
                                }
                                if let Err(e) = client_writer.flush().await {
                                    break Err(ProxyError::Io(e));
                                }
                            }
                            Some(MeResponse::Ack(_token)) => {
                                // QuickACK from ME — could forward to client as obfuscated ACK
                                // For now, just log
                                trace!(conn_id, "ME ACK (ignored)");
                            }
                            Some(MeResponse::Close) => {
                                debug!(conn_id, "ME sent CLOSE");
                                server_closed = true;
                                if client_closed { break Ok(()); }
                            }
                            None => {
                                // Channel closed — ME connection died
                                debug!(conn_id, "ME channel closed");
                                server_closed = true;
                                if client_closed { break Ok(()); }
                                break Err(ProxyError::Proxy("ME connection lost".into()));
                            }
                        }
                    }
    
                    // Both sides closed
                    else => {
                        break Ok(());
                    }
                }
            };
    
            // Cleanup
            debug!(user = %user, conn_id, "ME relay cleanup");
            me_pool.registry().unregister(conn_id).await;
            stats.decrement_user_curr_connects(&user);
    
            match &result {
                Ok(()) => debug!(user = %user, conn_id, "ME relay completed"),
                Err(e) => debug!(user = %user, conn_id, error = %e, "ME relay error"),
            }
    
            result
        }
    
        // =====================================================================
        // Helpers
        // =====================================================================
    
        fn check_user_limits_static(user: &str, config: &ProxyConfig, stats: &Stats) -> Result<()> {
            if let Some(expiration) = config.access.user_expirations.get(user) {
                if chrono::Utc::now() > *expiration {
                    return Err(ProxyError::UserExpired { user: user.to_string() });
                }
            }
    
            if let Some(limit) = config.access.user_max_tcp_conns.get(user) {
                if stats.get_user_curr_connects(user) >= *limit as u64 {
                    return Err(ProxyError::ConnectionLimitExceeded { user: user.to_string() });
                }
            }
    
            if let Some(quota) = config.access.user_data_quota.get(user) {
                if stats.get_user_total_octets(user) >= *quota {
                    return Err(ProxyError::DataQuotaExceeded { user: user.to_string() });
                }
            }
    
            Ok(())
        }
    
        /// Resolve DC index to target address (used only in direct mode)
        fn get_dc_addr_static(dc_idx: i16, config: &ProxyConfig) -> Result<SocketAddr> {
            let datacenters = if config.general.prefer_ipv6 {
                &*TG_DATACENTERS_V6
            } else {
                &*TG_DATACENTERS_V4
            };
    
            let num_dcs = datacenters.len();
    
            let dc_key = dc_idx.to_string();
            if let Some(addr_str) = config.dc_overrides.get(&dc_key) {
                match addr_str.parse::<SocketAddr>() {
                    Ok(addr) => {
                        debug!(dc_idx = dc_idx, addr = %addr, "Using DC override from config");
                        return Ok(addr);
                    }
                    Err(_) => {
                        warn!(dc_idx = dc_idx, addr_str = %addr_str,
                            "Invalid DC override address in config, ignoring");
                    }
                }
            }
    
            let abs_dc = dc_idx.unsigned_abs() as usize;
            if abs_dc >= 1 && abs_dc <= num_dcs {
                return Ok(SocketAddr::new(datacenters[abs_dc - 1], TG_DATACENTER_PORT));
            }
    
            let default_dc = config.default_dc.unwrap_or(2) as usize;
            let fallback_idx = if default_dc >= 1 && default_dc <= num_dcs {
                default_dc - 1
            } else {
                1
            };
    
            info!(
                original_dc = dc_idx,
                fallback_dc = (fallback_idx + 1) as u16,
                fallback_addr = %datacenters[fallback_idx],
                "Special DC ---> default_cluster"
            );
    
            Ok(SocketAddr::new(datacenters[fallback_idx], TG_DATACENTER_PORT))
        }
    
        /// Perform obfuscated handshake with Telegram DC (direct mode only)
        async fn do_tg_handshake_static(
            mut stream: TcpStream,
            success: &HandshakeSuccess,
            config: &ProxyConfig,
            rng: &SecureRandom,
        ) -> Result<(CryptoReader<tokio::net::tcp::OwnedReadHalf>, CryptoWriter<tokio::net::tcp::OwnedWriteHalf>)> {
            let (nonce, tg_enc_key, tg_enc_iv, tg_dec_key, tg_dec_iv) = generate_tg_nonce(
                success.proto_tag,
                success.dc_idx,
                &success.dec_key,
                success.dec_iv,
                rng,
                config.general.fast_mode,
            );
    
            let encrypted_nonce = encrypt_tg_nonce(&nonce);
    
            debug!(
                peer = %success.peer,
                nonce_head = %hex::encode(&nonce[..16]),
                "Sending nonce to Telegram"
            );
    
            stream.write_all(&encrypted_nonce).await?;
            stream.flush().await?;
    
            let (read_half, write_half) = stream.into_split();
    
            let decryptor = AesCtr::new(&tg_dec_key, tg_dec_iv);
            let encryptor = AesCtr::new(&tg_enc_key, tg_enc_iv);
    
            Ok((
                CryptoReader::new(read_half, decryptor),
                CryptoWriter::new(write_half, encryptor),
            ))
        }
    }
    