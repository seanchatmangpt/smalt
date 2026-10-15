//! Real compiled-binary conformance tests GENERATED from the admitted CLI graph.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

const BINARY: &str = env!("CARGO_BIN_EXE_smaltctl");

struct TestWorkspace {
    root: PathBuf,
}

impl TestWorkspace {
    fn new(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("the test clock must be after the Unix epoch")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("smaltctl-{label}-{}-{nonce}", std::process::id()));
        fs::create_dir_all(&root).expect("create isolated CLI test workspace");
        Self { root }
    }

    #[allow(dead_code)]
    fn path(&self) -> &Path {
        &self.root
    }

    fn run(&self, noun: &str, verb: &str, arguments: &[&str]) -> Output {
        let mut command = Command::new(BINARY);
        command
            .current_dir(&self.root)
            .arg(noun)
            .arg(verb)
            .args(arguments);
        command.output().expect("execute generated CLI binary")
    }
}

impl Drop for TestWorkspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[allow(dead_code)]
fn parse_stdout(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!(
            "generated CLI stdout must be JSON: {error}; stdout={:?}; stderr={:?}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

#[test]
fn real_cli_refuses_unknown_surface() {
    let workspace = TestWorkspace::new("unknown-command");
    let output = workspace.run("ggen-absent-noun", "ggen-absent-verb", &[]);
    assert!(
        !output.status.success(),
        "unknown command surface must fail closed"
    );
}
