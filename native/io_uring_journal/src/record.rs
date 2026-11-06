//! Checksummed journal record framing.
//!
//! On-disk layout (one record = one framed buffer):
//! `[u32 LE payload_len][u32 LE crc32(payload)][payload][zero padding to ALIGN]`

use crate::error::JournalError;
use crc32fast::Hasher;
use std::alloc::{alloc_zeroed, dealloc, Layout};

/// O_DIRECT / NVMe logical block alignment.
pub const ALIGN: usize = 512;
/// len + crc
pub const HEADER_LEN: usize = 8;

/// A heap buffer whose base address is guaranteed `align`-aligned via
/// `Layout` alignment (the System allocator honors layout alignment).
pub struct AlignedBuf {
    ptr: *mut u8,
    len: usize,
    layout: Layout,
}

// The buffer is owned exclusively; raw pointer is only used for read/write
// within a single owner. Not shared across threads.
unsafe impl Send for AlignedBuf {}

impl AlignedBuf {
    pub fn zeroed(len: usize, align: usize) -> AlignedBuf {
        assert!(align.is_power_of_two() && len > 0);
        let layout = Layout::from_size_align(len, align).expect("valid layout");
        // SAFETY: layout has non-zero size; align is a power of two.
        let ptr = unsafe { alloc_zeroed(layout) };
        if ptr.is_null() {
            std::alloc::handle_alloc_error(layout);
        }
        AlignedBuf { ptr, len, layout }
    }

    pub fn as_slice(&self) -> &[u8] {
        // SAFETY: ptr is valid for `len` bytes for the lifetime of self.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }

    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        // SAFETY: ptr is valid for `len` bytes, exclusively borrowed.
        unsafe { std::slice::from_raw_parts_mut(self.ptr, self.len) }
    }
}

impl Drop for AlignedBuf {
    fn drop(&mut self) {
        // SAFETY: allocated with exactly this layout, never freed elsewhere.
        unsafe { dealloc(self.ptr, self.layout) }
    }
}

#[derive(Debug, Clone)]
pub struct Record {
    payload: Vec<u8>,
}

impl Record {
    pub fn new(payload: Vec<u8>) -> Self {
        Record { payload }
    }

    pub fn payload(&self) -> &[u8] {
        &self.payload
    }

    pub fn checksum(&self) -> u32 {
        let mut h = Hasher::new();
        h.update(&self.payload);
        h.finalize()
    }

    /// Recompute and compare against a stored checksum (used when replaying
    /// a decoded frame against a separately-read header).
    pub fn verify_against(&self, expected: u32) -> Result<(), JournalError> {
        let actual = self.checksum();
        if actual == expected {
            Ok(())
        } else {
            Err(JournalError::ChecksumMismatch { expected, actual })
        }
    }

    pub fn encoded_len(&self) -> usize {
        let raw = HEADER_LEN + self.payload.len();
        round_up(raw, ALIGN)
    }

    /// Encode into a fresh `ALIGN`-aligned, zero-padded buffer suitable for
    /// O_DIRECT writes (offset and length alignment are caller-verified).
    pub fn encode(&self) -> AlignedBuf {
        let total = self.encoded_len();
        let mut buf = AlignedBuf::zeroed(total, ALIGN);
        let s = buf.as_mut_slice();
        s[0..4].copy_from_slice(&(self.payload.len() as u32).to_le_bytes());
        s[4..8].copy_from_slice(&self.checksum().to_le_bytes());
        s[HEADER_LEN..HEADER_LEN + self.payload.len()].copy_from_slice(&self.payload);
        buf
    }

    /// Decode a single record from a padded buffer. The padding after the
    /// payload is ignored; a cut-off header or payload is `TruncatedRecord`.
    pub fn decode(buf: &[u8]) -> Result<Record, JournalError> {
        if buf.len() < HEADER_LEN {
            return Err(JournalError::TruncatedRecord);
        }
        let len = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        let crc = u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]);
        if HEADER_LEN + len > buf.len() {
            return Err(JournalError::TruncatedRecord);
        }
        let payload = buf[HEADER_LEN..HEADER_LEN + len].to_vec();
        let rec = Record { payload };
        let mut h = Hasher::new();
        h.update(&rec.payload);
        let actual = h.finalize();
        if actual != crc {
            return Err(JournalError::ChecksumMismatch { expected: crc, actual });
        }
        Ok(rec)
    }
}

pub fn round_up(n: usize, align: usize) -> usize {
    if n == 0 {
        return align;
    }
    n.div_ceil(align) * align
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encoded_buffer_is_512_aligned_and_padded() {
        let rec = Record::new(vec![7u8; 100]);
        let buf = rec.encode();
        assert_eq!(buf.as_slice().len(), ALIGN);
        assert_eq!(buf.as_slice().as_ptr() as usize % ALIGN, 0);
        assert_eq!(
            Record::decode(buf.as_slice()).unwrap().payload(),
            rec.payload()
        );
    }

    #[test]
    fn multi_block_payload_roundtrips() {
        let rec = Record::new(vec![0xA5u8; 1500]);
        let buf = rec.encode();
        assert_eq!(buf.as_slice().len(), 4 * ALIGN);
        assert_eq!(Record::decode(buf.as_slice()).unwrap().payload().len(), 1500);
    }

    #[test]
    fn corrupted_checksum_is_typed() {
        let mut buf = Record::new(vec![1u8; 32]).encode();
        buf.as_mut_slice()[4] ^= 0xFF;
        match Record::decode(buf.as_slice()) {
            Err(JournalError::ChecksumMismatch { .. }) => {}
            other => panic!("expected ChecksumMismatch, got {:?}", other.map(|_| ())),
        }
    }

    #[test]
    fn truncated_header_is_typed() {
        assert!(matches!(
            Record::decode(&[0u8; 3]),
            Err(JournalError::TruncatedRecord)
        ));
    }

    #[test]
    fn aligned_buf_alignment_holds_across_sizes() {
        for len in [ALIGN, 4 * ALIGN, 33 * ALIGN, 1000 * ALIGN] {
            let b = AlignedBuf::zeroed(len, ALIGN);
            assert_eq!(b.as_slice().as_ptr() as usize % ALIGN, 0);
            assert!(b.as_slice().iter().all(|&x| x == 0));
        }
    }
}
