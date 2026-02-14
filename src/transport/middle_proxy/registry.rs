use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};

use tokio::sync::{RwLock, mpsc};

use super::MeResponse;

pub struct ConnRegistry {
    map: RwLock<HashMap<u64, mpsc::Sender<MeResponse>>>,
    next_id: AtomicU64,
}

impl ConnRegistry {
    pub fn new() -> Self {
        // Avoid fully predictable conn_id sequence from 1.
        let start = rand::random::<u64>() | 1;
        Self {
            map: RwLock::new(HashMap::new()),
            next_id: AtomicU64::new(start),
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
        } else {
            false
        }
    }
}
