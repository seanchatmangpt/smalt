use std::fmt;

#[derive(Debug)]
pub enum JournalError {
    /// Typed platform refusal: the direct journal is Linux-only.
    LinuxOnly { host: &'static str },
    /// O_DIRECT requires 512-aligned buffers/offsets/lengths; an unaligned
    /// caller buffer is refused, never silently copied.
    UnalignedBuffer { offset: usize, alignment: usize },
    Io(std::io::Error),
    ChecksumMismatch { expected: u32, actual: u32 },
    TruncatedRecord,
}

impl fmt::Display for JournalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            JournalError::LinuxOnly { host } => {
                write!(f, "Linux-only lane: direct io_uring journal requires {host}")
            }
            JournalError::UnalignedBuffer { offset, alignment } => {
                write!(f, "unaligned O_DIRECT buffer: offset {offset}, alignment {alignment}")
            }
            JournalError::Io(e) => write!(f, "io error: {e}"),
            JournalError::ChecksumMismatch { expected, actual } => {
                write!(f, "checksum mismatch: expected {expected:#010x}, actual {actual:#010x}")
            }
            JournalError::TruncatedRecord => write!(f, "truncated record"),
        }
    }
}

impl std::error::Error for JournalError {}

impl From<std::io::Error> for JournalError {
    fn from(e: std::io::Error) -> Self {
        JournalError::Io(e)
    }
}
