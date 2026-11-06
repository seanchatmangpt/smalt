//! Columnar append batches.
//!
//! A [`ColumnarBatch`] groups per-column byte buffers into a single framed
//! journal record: `[u32 col_count]([u32 col_len][col_bytes])...` becomes the
//! record payload, so one checksum covers the whole batch and one O_DIRECT
//! write lands it.

use crate::error::JournalError;
use crate::record::Record;

#[derive(Debug, Clone, Default)]
pub struct ColumnarBatch {
    columns: Vec<Vec<u8>>,
}

impl ColumnarBatch {
    pub fn new() -> Self {
        ColumnarBatch { columns: Vec::new() }
    }

    pub fn push_column(&mut self, data: Vec<u8>) {
        self.columns.push(data);
    }

    pub fn columns(&self) -> &[Vec<u8>] {
        &self.columns
    }

    /// Serialize columns into the record payload.
    pub fn encode_payload(&self) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&(self.columns.len() as u32).to_le_bytes());
        for col in &self.columns {
            payload.extend_from_slice(&(col.len() as u32).to_le_bytes());
            payload.extend_from_slice(col);
        }
        payload
    }

    pub fn to_record(&self) -> Record {
        Record::new(self.encode_payload())
    }

    /// Inverse of [`ColumnarBatch::to_record`] framing.
    pub fn from_record(rec: &Record) -> Result<ColumnarBatch, JournalError> {
        let p = rec.payload();
        if p.len() < 4 {
            return Err(JournalError::TruncatedRecord);
        }
        let n = u32::from_le_bytes([p[0], p[1], p[2], p[3]]) as usize;
        let mut i = 4;
        let mut cols = Vec::with_capacity(n.min(1024));
        for _ in 0..n {
            if i + 4 > p.len() {
                return Err(JournalError::TruncatedRecord);
            }
            let len = u32::from_le_bytes([p[i], p[i + 1], p[i + 2], p[i + 3]]) as usize;
            i += 4;
            if i + len > p.len() {
                return Err(JournalError::TruncatedRecord);
            }
            cols.push(p[i..i + len].to_vec());
            i += len;
        }
        Ok(ColumnarBatch { columns: cols })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batch_roundtrips_through_record_framing() {
        let mut b = ColumnarBatch::new();
        b.push_column(vec![1, 2, 3]);
        b.push_column(vec![42u8; 600]);
        b.push_column(Vec::new());
        let rec = b.to_record();
        let back = ColumnarBatch::from_record(&rec).unwrap();
        assert_eq!(back.columns(), b.columns());
    }

    #[test]
    fn truncated_column_header_is_typed() {
        let mut b = ColumnarBatch::new();
        b.push_column(vec![1, 2, 3]);
        let rec = b.to_record();
        // Cut the payload so the column length header overruns.
        let cut = &rec.payload()[..5];
        let trunc = Record::new(cut.to_vec());
        assert!(matches!(
            ColumnarBatch::from_record(&trunc),
            Err(JournalError::TruncatedRecord)
        ));
    }

    #[test]
    fn empty_batch_roundtrips() {
        let b = ColumnarBatch::new();
        let back = ColumnarBatch::from_record(&b.to_record()).unwrap();
        assert_eq!(back.columns().len(), 0);
    }
}
