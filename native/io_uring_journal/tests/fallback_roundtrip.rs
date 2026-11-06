//! Host-independent framing integration test: writes real records through
//! the host-appropriate journal to a real temp file and reads them back,
//! verifying checksums on replay. Chicago-style: real files, real IO, no mocks.

use io_uring_journal::columnar::ColumnarBatch;
use io_uring_journal::record::{Record, ALIGN};
use std::io::{Read, Seek, SeekFrom};

struct TempFile(std::path::PathBuf);

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

#[test]
fn write_then_replay_roundtrip_on_host_path() {
    let dir = std::env::temp_dir();
    let path = dir.join(format!("uring-journal-test-{}.log", std::process::id()));
    let tmp = TempFile(path.clone());

    // Host-appropriate journal: direct on linux, datasync fallback elsewhere.
    #[cfg(target_os = "linux")]
    let mut j = io_uring_journal::uring::UringJournal::open(&path).expect("open direct journal");
    #[cfg(not(target_os = "linux"))]
    let mut j = io_uring_journal::fallback::FallbackJournal::open(&path).expect("open fallback journal");

    let mut batch = ColumnarBatch::new();
    batch.push_column(vec![1, 2, 3, 4]);
    batch.push_column(vec![0xEEu8; 1000]);

    let records = vec![
        Record::new(b"first record".to_vec()),
        Record::new((0..2000).map(|i| (i % 251) as u8).collect()),
        batch.to_record(),
    ];
    let expected: Vec<Vec<u8>> = records.iter().map(|r| r.payload().to_vec()).collect();

    for rec in &records {
        // Both journal types expose record append via their concrete API.
        #[cfg(target_os = "linux")]
        {
            let buf = rec.encode();
            j.append_record(&buf).expect("direct append");
        }
        #[cfg(not(target_os = "linux"))]
        j.append_record(rec).expect("fallback append");
    }
    j.sync().expect("sync");

    // Replay: read the raw file (padded to ALIGN multiples) and decode.
    let mut f = std::fs::File::open(&path).unwrap();
    let mut raw = Vec::new();
    f.read_to_end(&mut raw).unwrap();
    assert_eq!(raw.len() % ALIGN, 0, "file length must stay block-aligned");

    let mut replayed = Vec::new();
    let mut off = 0usize;
    while off < raw.len() {
        // Skip runs of pure padding (zero blocks between framed records are
        // padding only because every record fills its own blocks exactly).
        if raw[off..].iter().all(|&b| b == 0) {
            break;
        }
        let rec = Record::decode(&raw[off..]).expect("decode record");
        replayed.push(rec.payload().to_vec());
        let raw_len = 8 + rec.payload().len();
        off += raw_len.div_ceil(ALIGN) * ALIGN;
    }
    assert_eq!(replayed, expected);
}
