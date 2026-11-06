//! Non-linux fallback: same record framing, std buffered write + datasync.
//!
//! This exists so the crate compiles and the framing logic is exercised on
//! darwin dev hosts. It has NO io_uring and NO O_DIRECT semantics and must
//! never be benchmarked or claimed as the fast path. Opening the *direct*
//! journal on these hosts is refused via `require_linux`; this module is
//! opt-in and labeled.

use crate::columnar::ColumnarBatch;
use crate::error::JournalError;
use crate::record::Record;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;

pub struct FallbackJournal {
    file: std::fs::File,
}

impl FallbackJournal {
    pub fn open(path: &Path) -> Result<FallbackJournal, JournalError> {
        let file = OpenOptions::new().append(true).create(true).open(path)?;
        Ok(FallbackJournal { file })
    }

    /// Append a record (plain buffered write of the framed payload; the
    /// alignment padding is kept so on-disk framing is host-independent).
    pub fn append_record(&mut self, rec: &Record) -> Result<(), JournalError> {
        let buf = rec.encode();
        self.file.write_all(buf.as_slice())?;
        Ok(())
    }

    pub fn append_batch(&mut self, batch: &ColumnarBatch) -> Result<(), JournalError> {
        self.append_record(&batch.to_record())
    }

    /// Durable barrier via datasync (the darwin/dev path).
    pub fn sync(&mut self) -> Result<(), JournalError> {
        self.file.sync_data()?;
        Ok(())
    }
}
