use std::sync::Arc;

use bytes::{Bytes, BytesMut};
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use tracing::{debug, trace, warn};

use crate::crypto::{AesCbc, crc32};
use crate::error::{ProxyError, Result};
use crate::protocol::constants::*;

use super::codec::RpcWriter;
use super::{ConnRegistry, MeResponse};

pub(crate) async fn reader_loop(
    mut rd: tokio::io::ReadHalf<TcpStream>,
    dk: [u8; 32],
    mut div: [u8; 16],
    reg: Arc<ConnRegistry>,
    enc_leftover: BytesMut,
    mut dec: BytesMut,
    writer: Arc<Mutex<RpcWriter>>,
) -> Result<()> {
    let mut raw = enc_leftover;

    loop {
        let mut tmp = [0u8; 16_384];
        let n = rd.read(&mut tmp).await.map_err(ProxyError::Io)?;
        if n == 0 {
            return Ok(());
        }
        raw.extend_from_slice(&tmp[..n]);

        let blocks = raw.len() / 16 * 16;
        if blocks > 0 {
            let mut new_iv = [0u8; 16];
            new_iv.copy_from_slice(&raw[blocks - 16..blocks]);

            let mut chunk = vec![0u8; blocks];
            chunk.copy_from_slice(&raw[..blocks]);
            AesCbc::new(dk, div)
                .decrypt_in_place(&mut chunk)
                .map_err(|e| ProxyError::Crypto(format!("{e}")))?;
            div = new_iv;
            dec.extend_from_slice(&chunk);
            let _ = raw.split_to(blocks);
        }

        while dec.len() >= 12 {
            let fl = u32::from_le_bytes(dec[0..4].try_into().unwrap()) as usize;
            if fl == 4 {
                let _ = dec.split_to(4);
                continue;
            }
            if !(12..=(1 << 24)).contains(&fl) {
                warn!(frame_len = fl, "Invalid RPC frame len");
                dec.clear();
                break;
            }
            if dec.len() < fl {
                break;
            }

            let frame = dec.split_to(fl);
            let pe = fl - 4;
            let ec = u32::from_le_bytes(frame[pe..pe + 4].try_into().unwrap());
            if crc32(&frame[..pe]) != ec {
                warn!("CRC mismatch in data frame");
                continue;
            }

            let payload = &frame[8..pe];
            if payload.len() < 4 {
                continue;
            }

            let pt = u32::from_le_bytes(payload[0..4].try_into().unwrap());
            let body = &payload[4..];

            if pt == RPC_PROXY_ANS_U32 && body.len() >= 12 {
                let flags = u32::from_le_bytes(body[0..4].try_into().unwrap());
                let cid = u64::from_le_bytes(body[4..12].try_into().unwrap());
                let data = Bytes::copy_from_slice(&body[12..]);
                trace!(cid, flags, len = data.len(), "RPC_PROXY_ANS");

                let routed = reg.route(cid, MeResponse::Data { flags, data }).await;
                if !routed {
                    reg.unregister(cid).await;
                    send_close_conn(&writer, cid).await;
                }
            } else if pt == RPC_SIMPLE_ACK_U32 && body.len() >= 12 {
                let cid = u64::from_le_bytes(body[0..8].try_into().unwrap());
                let cfm = u32::from_le_bytes(body[8..12].try_into().unwrap());
                trace!(cid, cfm, "RPC_SIMPLE_ACK");

                let routed = reg.route(cid, MeResponse::Ack(cfm)).await;
                if !routed {
                    reg.unregister(cid).await;
                    send_close_conn(&writer, cid).await;
                }
            } else if pt == RPC_CLOSE_EXT_U32 && body.len() >= 8 {
                let cid = u64::from_le_bytes(body[0..8].try_into().unwrap());
                debug!(cid, "RPC_CLOSE_EXT from ME");
                reg.route(cid, MeResponse::Close).await;
                reg.unregister(cid).await;
            } else if pt == RPC_CLOSE_CONN_U32 && body.len() >= 8 {
                let cid = u64::from_le_bytes(body[0..8].try_into().unwrap());
                debug!(cid, "RPC_CLOSE_CONN from ME");
                reg.route(cid, MeResponse::Close).await;
                reg.unregister(cid).await;
            } else if pt == RPC_PING_U32 && body.len() >= 8 {
                let ping_id = i64::from_le_bytes(body[0..8].try_into().unwrap());
                trace!(ping_id, "RPC_PING -> RPC_PONG");
                let mut pong = Vec::with_capacity(12);
                pong.extend_from_slice(&RPC_PONG_U32.to_le_bytes());
                pong.extend_from_slice(&ping_id.to_le_bytes());
                if let Err(e) = writer.lock().await.send(&pong).await {
                    warn!(error = %e, "PONG send failed");
                    break;
                }
            } else {
                debug!(
                    rpc_type = format_args!("0x{pt:08x}"),
                    len = body.len(),
                    "Unknown RPC"
                );
            }
        }
    }
}

async fn send_close_conn(writer: &Arc<Mutex<RpcWriter>>, conn_id: u64) {
    let mut p = Vec::with_capacity(12);
    p.extend_from_slice(&RPC_CLOSE_CONN_U32.to_le_bytes());
    p.extend_from_slice(&conn_id.to_le_bytes());

    if let Err(e) = writer.lock().await.send(&p).await {
        debug!(conn_id, error = %e, "Failed to send RPC_CLOSE_CONN");
    }
}
