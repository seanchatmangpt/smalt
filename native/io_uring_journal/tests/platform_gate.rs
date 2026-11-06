//! Platform gate: the direct io_uring/O_DIRECT journal is Linux-only.
//!
//! On non-linux this test FAILS LOUDLY with a typed "Linux-only lane"
//! message — it never silently skips. That red-on-darwin gate is the point:
//! absence of the Linux runtime path must be visible, not absorbed.

use io_uring_journal::{require_linux, JournalError};

#[test]
fn direct_journal_is_linux_only() {
    match require_linux() {
        Ok(()) => {
            // On Linux: the direct path must be compiled in.
            #[cfg(target_os = "linux")]
            {
                let _ = io_uring_journal::uring::UringJournal::open; // compiled-in witness
            }
        }
        Err(JournalError::LinuxOnly { host }) => {
            let is_linux = cfg!(target_os = "linux");
            assert!(!is_linux, "LinuxOnly refusal on a linux host is a defect");
            panic!(
                "Linux-only lane: io_uring/O_DIRECT direct journal refused on this host \
                 (required platform: {host}). This red gate is intentional on non-linux; \
                 the darwin datasync fallback is compiled but is NOT the direct path."
            );
        }
    }
}
