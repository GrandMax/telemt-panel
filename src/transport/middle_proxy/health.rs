use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use tracing::{debug, info, warn};

use crate::crypto::SecureRandom;
use crate::protocol::constants::TG_MIDDLE_PROXIES_FLAT_V4;

use super::MePool;

pub async fn me_health_monitor(pool: Arc<MePool>, rng: Arc<SecureRandom>, min_connections: usize) {
    loop {
        tokio::time::sleep(Duration::from_secs(30)).await;
        let current = pool.connection_count();
        if current < min_connections {
            warn!(
                current,
                min = min_connections,
                "ME pool below minimum, reconnecting..."
            );
            let addrs = TG_MIDDLE_PROXIES_FLAT_V4.clone();
            for &(ip, port) in addrs.iter() {
                let needed = min_connections.saturating_sub(pool.connection_count());
                if needed == 0 {
                    break;
                }
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
