pub mod data_storage;
pub mod dps_calculator;
pub mod fight_buffs;
pub mod hit_log;
pub mod ping_tracker;

// Owns the capture threads and the tokio channel they feed.
#[cfg(feature = "desktop")]
pub mod capture_dispatcher;
