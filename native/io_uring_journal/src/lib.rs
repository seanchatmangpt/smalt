//! io_uring/O_DIRECT NVMe append journal.
//!
//! Platform scoping (honest):
//! - `#[cfg(target_os = "linux")]` module `uring` implements the real
//!   io_uring + O_DIRECT append path (aligned buffers, checksummed records).
//! - Non-linux hosts get a `FallbackJournal` that keeps the same record
//!   framing but uses `File::sync_data` (datasync). This path exists so the
//!   crate compiles and the framing logic is testable on darwin; it is NOT
//!   claimed to have io_uring/O_DIRECT semantics and is never benchmarked.
//!
//! The direct journal refuses to open on non-linux with
//! [`JournalError::LinuxOnly`] — the refusal is typed, not a silent skip.

pub mod error;
pub mod record;
pub mod columnar;

#[cfg(target_os = "linux")]
pub mod uring;

#[cfg(not(target_os = "linux"))]
pub mod fallback;

pub use error::JournalError;
pub use record::{Record, HEADER_LEN, ALIGN};
pub use columnar::ColumnarBatch;

/// Platform gate. The direct (io_uring/O_DIRECT) journal is Linux-only by
/// construction; every other host must receive a typed refusal.
pub const REQUIRED_PLATFORM: &str = "linux";

pub fn require_linux() -> Result<(), JournalError> {
    if cfg!(target_os = "linux") {
        Ok(())
    } else {
        Err(JournalError::LinuxOnly {
            host: REQUIRED_PLATFORM,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_gate_types_a_refusal_on_non_linux() {
        let res = require_linux();
        if cfg!(target_os = "linux") {
            assert!(res.is_ok());
        } else {
            match res {
                Err(JournalError::LinuxOnly { host }) => {
                    assert_eq!(host, "linux");
                }
                other => panic!("expected typed LinuxOnly refusal, got {:?}", other),
            }
        }
    }

    #[test]
    fn record_roundtrip_on_any_host() {
        let rec = Record::new(b"hello nvme".to_vec());
        let bytes = rec.encode();
        let decoded = Record::decode(bytes.as_slice()).unwrap();
        assert_eq!(decoded.payload(), rec.payload());
    }
}
