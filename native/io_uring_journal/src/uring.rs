//! Linux-only io_uring + O_DIRECT journal append path.
//!
//! Implementation notes (honest scoping):
//! - File is opened with `O_DIRECT | O_APPEND | O_CREAT | O_WRONLY`. O_DIRECT
//!   requires the buffer base address, the file offset, and the write length
//!   to be aligned to the logical block size (512 here); records are zero-
//!   padded to `ALIGN` and allocated via `Layout` alignment to satisfy that.
//! - Appends go through a persistent `io_uring` ring: `writev`-style write
//!   submission per record, completion reaped with
//!   `submitter.submit_and_wait(1)`. Durability is a separate
//!   `io_uring::opcode::Fsync` (fdatasync) submission so callers can batch.
//! - No throughput numbers are claimed anywhere in this crate; this module
//!   has only ever been compile-checked in environments where the runtime
//!   path can be exercised on real NVMe storage (Linux + O_DIRECT-capable fs).
//! - `O_DIRECT` is rejected by some filesystems (e.g. tmpfs historically
//!   allows it on newer kernels, others don't); open failures surface as
//!   [`JournalError::Io`], never silently degraded to buffered IO.

use crate::columnar::ColumnarBatch;
use crate::error::JournalError;
use crate::record::{round_up, AlignedBuf, ALIGN};
use io_uring::{opcode, types, IoUring};
use std::fs::OpenOptions;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::AsRawFd;
use std::path::Path;

pub struct UringJournal {
    ring: IoUring,
    file: std::fs::File,
    /// O_APPEND keeps kernel-side offset serialization; we still track the
    /// aligned offset for records that require it.
    file_offset: u64,
}

impl UringJournal {
    /// Open (creating if needed) an O_DIRECT journal at `path`.
    pub fn open(path: &Path) -> Result<UringJournal, JournalError> {
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .custom_flags(libc::O_DIRECT | libc::O_APPEND)
            .open(path)?;
        // Size the ring to a modest depth; appends are serialized by O_APPEND
        // semantics so deeper rings buy nothing for this access pattern.
        let ring = IoUring::new(64)?;
        let file_offset = file.metadata()?.len();
        Ok(UringJournal { ring, file, file_offset })
    }

    /// Append one already-encoded record buffer (must be `ALIGN`-aligned and
    /// `ALIGN`-multiple length, as produced by `Record::encode`).
    pub fn append_record(&mut self, buf: &AlignedBuf) -> Result<(), JournalError> {
        let len = buf.as_slice().len();
        if len % ALIGN != 0 {
            return Err(JournalError::UnalignedBuffer { offset: len, alignment: ALIGN });
        }
        let off = round_up(self.file_offset as usize, ALIGN) as u64;
        let write = opcode::Write::new(types::Fd(self.file.as_raw_fd()), buf.as_slice().as_ptr(), len as u32)
            .offset(off)
            .build();

        unsafe {
            self.ring
                .submission()
                .push(&write)
                .map_err(|e| JournalError::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?;
        }
        self.ring.submit_and_wait(1)?;
        let cqe = self
            .ring
            .completion()
            .next()
            .ok_or_else(|| JournalError::Io(std::io::Error::new(std::io::ErrorKind::Other, "ring empty")))?;
        let res = cqe.result();
        if res < 0 {
            return Err(JournalError::Io(std::io::Error::from_raw_os_error(-res)));
        }
        debug_assert_eq!(res as usize, len);
        self.file_offset = off + len as u64;
        Ok(())
    }

    /// Encode + append a columnar batch as one checksummed record.
    pub fn append_batch(&mut self, batch: &ColumnarBatch) -> Result<(), JournalError> {
        let buf = batch.to_record().encode();
        self.append_record(&buf)
    }

    /// Durable barrier: fdatasync submitted through the same ring.
    pub fn sync(&mut self) -> Result<(), JournalError> {
        let fsync = opcode::Fsync::new(types::Fd(self.file.as_raw_fd()))
            .flags(types::FsyncFlags::DATASYNC)
            .build();
        unsafe {
            self.ring
                .submission()
                .push(&fsync)
                .map_err(|e| JournalError::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?;
        }
        self.ring.submit_and_wait(1)?;
        let cqe = self
            .ring
            .completion()
            .next()
            .ok_or_else(|| JournalError::Io(std::io::Error::new(std::io::ErrorKind::Other, "ring empty")))?;
        let res = cqe.result();
        if res < 0 {
            return Err(JournalError::Io(std::io::Error::from_raw_os_error(-res)));
        }
        Ok(())
    }
}
