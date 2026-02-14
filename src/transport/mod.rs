//! Transport layer: connection pooling, socket utilities, proxy protocol

pub mod pool;
pub mod proxy_protocol;
pub mod socket;
pub mod socks;
pub mod upstream;

pub use pool::ConnectionPool;
pub use proxy_protocol::{ProxyProtocolInfo, parse_proxy_protocol};
pub use socket::*;
pub use socks::*;
pub use upstream::{DcPingResult, StartupPingResult, UpstreamManager};
pub mod middle_proxy;
