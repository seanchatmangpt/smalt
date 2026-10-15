//! Hand-written domain logic for every `cnv:CustomBehavior` command.
//!
//! GENERATED ONCE by ggen (`unless_exists: true` — this file is scaffolding,
//! never overwritten by a later `ggen sync run`, so your edits below are
//! safe). Every function here is actuated by `src/generated_cli.rs`. HTTP is
//! done via a curl subprocess (no extra crate deps; TLS via libcurl); the
//! doctor/court proxies use std::process::Command.

use clap_noun_verb::NounVerbError;
use clap_noun_verb::Result;
use serde_json::{json, Map, Value};
use std::process::Command;

/// ARM gateway base URL (env: SMALT_ARM_URL).
fn arm_url() -> String {
    std::env::var("SMALT_ARM_URL").unwrap_or_else(|_| "http://127.0.0.1:9443".into())
}

/// Egress plane base URL (env: SMALT_EGRESS_URL).
fn egress_url() -> String {
    std::env::var("SMALT_EGRESS_URL").unwrap_or_else(|_| "http://127.0.0.1:8443".into())
}

/// Optional bearer token (env: SMALT_BEARER_TOKEN).
fn auth_header() -> Vec<String> {
    match std::env::var("SMALT_BEARER_TOKEN") {
        Ok(tok) if !tok.is_empty() => vec![format!("Authorization: Bearer {tok}")],
        _ => vec![],
    }
}

fn err(msg: impl std::fmt::Display) -> NounVerbError {
    NounVerbError::ExecutionError { message: msg.to_string() }
}

/// One HTTP round trip via curl. Returns (status, body).
fn http(
    method: &str,
    url: &str,
    headers: &[String],
    body: Option<&str>,
    file: Option<&std::path::Path>,
) -> Result<(u32, String)> {
    let mut cmd = Command::new("curl");
    cmd.args(["-sS", "-m", "15", "-x", "", "-w", "\n%{http_code}", "-X", method, url]);
    for h in headers {
        cmd.arg("-H").arg(h);
    }
    if let Some(b) = body {
        cmd.arg("--data-binary").arg(b);
    }
    if let Some(f) = file {
        cmd.arg("--data-binary").arg(format!("@{}", f.display()));
    }
    let out = cmd.output().map_err(|e| err(format!("curl spawn failed: {e}")))?;
    if !out.status.success() && out.stdout.is_empty() {
        return Err(err(format!(
            "curl failed: {}",
            String::from_utf8_lossy(&out.stderr)
        )));
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let (body, code) = match text.rsplit_once('\n') {
        Some((b, c)) => (b.to_string(), c.trim().parse::<u32>().unwrap_or(0)),
        None => (text.to_string(), 0),
    };
    Ok((code, body))
}

fn require_2xx(code: u32, body: &str) -> Result<()> {
    if (200..300).contains(&code) {
        Ok(())
    } else {
        Err(err(format!("HTTP {code}: {body}")))
    }
}

fn get_str(inputs: &Map<String, Value>, key: &str) -> Result<String> {
    inputs
        .get(key)
        .map(|v| v.as_str().unwrap_or_default().to_string())
        .ok_or_else(|| err(format!("missing argument: {key}")))
}

fn get_opt_str(inputs: &Map<String, Value>, key: &str) -> Option<String> {
    inputs.get(key).and_then(|v| v.as_str().map(String::from))
}

/// Run a command, streaming nothing; returns (status, stdout).
fn run_process(program: &str, args: &[&str], cwd: Option<&str>) -> Result<(i32, String)> {
    let mut cmd = Command::new(program);
    cmd.args(args);
    if let Some(d) = cwd {
        cmd.current_dir(d);
    }
    let out = cmd.output().map_err(|e| err(format!("spawn {program}: {e}")))?;
    let mut text = String::from_utf8_lossy(&out.stdout).to_string();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    let code = out.status.code().unwrap_or(-1);
    Ok((code, text))
}

/// Repo root (env: SMALT_REPO, default ".").
fn repo_root() -> String {
    std::env::var("SMALT_REPO").unwrap_or_else(|_| ".".into())
}

// ---------------------------------------------------------------------------
// status
// ---------------------------------------------------------------------------

/// `status list` -- GET /subscriptions + /metadata/endpoints from the ARM
/// gateway, merged into one JSON document.
pub fn status_list(_inputs: Map<String, Value>) -> Result<Value> {
    let (code, body) = http("GET", &format!("{}/subscriptions", arm_url()), &auth_header(), None, None)?;
    require_2xx(code, &body)?;
    let subs: Value = serde_json::from_str(&body).map_err(|e| err(format!("bad JSON: {e}")))?;

    let (mcode, mbody) = http(
        "GET",
        &format!("{}/metadata/endpoints", arm_url()),
        &auth_header(),
        None,
        None,
    )?;
    let metadata: Value = if (200..300).contains(&mcode) {
        serde_json::from_str(&mbody).unwrap_or(Value::Null)
    } else {
        Value::Null
    };

    Ok(json!({
        "subscriptions": subs.get("value").cloned().unwrap_or(subs),
        "metadata": metadata,
        "arm_url": arm_url(),
        "egress_url": egress_url(),
    }))
}

// ---------------------------------------------------------------------------
// kv
// ---------------------------------------------------------------------------

/// `kv create` -- POST /keys/:name/create.
pub fn kv_create(inputs: Map<String, Value>) -> Result<Value> {
    let name = get_str(&inputs, "name")?;
    let url = format!("{}/keys/{}/create", egress_url(), name);
    let mut hdrs = vec!["Content-Type: application/json".to_string()];
    hdrs.extend(auth_header());
    let payload = match get_opt_str(&inputs, "release_policy") {
        Some(p) => serde_json::to_string(&json!({
            "release_policy": serde_json::from_str::<Value>(&p)
                .map_err(|e| err(format!("bad release-policy JSON: {e}")))?
        }))
        .map_err(|e| err(format!("encode: {e}")))?,
        None => "{}".to_string(),
    };
    let (code, body) = http("POST", &url, &hdrs, Some(&payload), None)?;
    require_2xx(code, &body)?;
    serde_json::from_str(&body).map_err(|e| err(format!("bad JSON: {e}")))
}

/// `kv get` -- GET /keys/:name.
pub fn kv_get(inputs: Map<String, Value>) -> Result<Value> {
    let name = get_str(&inputs, "name")?;
    let url = format!("{}/keys/{}", egress_url(), name);
    let (code, body) = http("GET", &url, &auth_header(), None, None)?;
    require_2xx(code, &body)?;
    serde_json::from_str(&body).map_err(|e| err(format!("bad JSON: {e}")))
}

/// `kv list` -- GET /keys.
pub fn kv_list(_inputs: Map<String, Value>) -> Result<Value> {
    let (code, body) = http("GET", &format!("{}/keys", egress_url()), &auth_header(), None, None)?;
    require_2xx(code, &body)?;
    serde_json::from_str(&body).map_err(|e| err(format!("bad JSON: {e}")))
}

/// `kv release` -- POST /keys/:name/release.
pub fn kv_release(inputs: Map<String, Value>) -> Result<Value> {
    let name = get_str(&inputs, "name")?;
    let url = format!("{}/keys/{}/release", egress_url(), name);
    let mut hdrs = vec!["Content-Type: application/json".to_string()];
    hdrs.extend(auth_header());
    let (code, body) = http("POST", &url, &hdrs, Some("{}"), None)?;
    require_2xx(code, &body)?;
    serde_json::from_str(&body).map_err(|e| err(format!("bad JSON: {e}")))
}

// ---------------------------------------------------------------------------
// blob
// ---------------------------------------------------------------------------

/// Blob routes require the x-ms-version header (egress blob_route guard).
fn blob_headers() -> Vec<String> {
    let mut hdrs = vec!["x-ms-version: 2021-08-06".to_string()];
    hdrs.extend(auth_header());
    hdrs
}

fn blob_base() -> String {
    let account = std::env::var("SMALT_BLOB_ACCOUNT").unwrap_or_else(|_| "smaltdev".into());
    format!("{}/{}", egress_url(), account)
}

/// `blob put` -- PUT /{account}/{container}/{blob} with the file as body.
pub fn blob_put(inputs: Map<String, Value>) -> Result<Value> {
    let container = get_str(&inputs, "container")?;
    let blob = get_str(&inputs, "blob_name")?;
    let file = get_str(&inputs, "file")?;
    let url = format!("{}/{}/{}", blob_base(), container, blob);
    let path = std::path::PathBuf::from(&file);
    if !path.is_file() {
        return Err(err(format!("not a file: {file}")));
    }
    let (code, body) = http("PUT", &url, &blob_headers(), None, Some(&path))?;
    require_2xx(code, &body)?;
    serde_json::from_str(&body).map_err(|e| err(format!("bad JSON: {e}")))
}

/// `blob get` -- GET /{account}/{container}/{blob}; body is not JSON, so it is
/// wrapped raw in a JSON string.
pub fn blob_get(inputs: Map<String, Value>) -> Result<Value> {
    let container = get_str(&inputs, "container")?;
    let blob = get_str(&inputs, "blob_name")?;
    let url = format!("{}/{}/{}", blob_base(), container, blob);
    let (code, body) = http("GET", &url, &blob_headers(), None, None)?;
    require_2xx(code, &body)?;
    Ok(Value::String(body))
}

/// `blob list` -- containers when no container given, else blobs in it.
pub fn blob_list(inputs: Map<String, Value>) -> Result<Value> {
    let container = get_opt_str(&inputs, "container");
    let (code, body) = match container {
        Some(ref c) => {
            let url = format!("{}/{}?comp=list&restype=container", blob_base(), c);
            http("GET", &url, &blob_headers(), None, None)?
        }
        None => {
            let url = format!("{}?comp=list", blob_base());
            http("GET", &url, &blob_headers(), None, None)?
        }
    };
    require_2xx(code, &body)?;
    Ok(json!({"container": get_opt_str(&inputs, "container"), "xml": body}))
}

/// `blob delete` -- DELETE /{account}/{container}/{blob}.
pub fn blob_delete(inputs: Map<String, Value>) -> Result<Value> {
    let container = get_str(&inputs, "container")?;
    let blob = get_str(&inputs, "blob_name")?;
    let url = format!("{}/{}/{}", blob_base(), container, blob);
    let mut cmd = Command::new("curl");
    cmd.args(["-sS", "-m", "15", "-w", "\n%{http_code}", "-X", "DELETE", &url]);
    for h in blob_headers() {
        cmd.arg("-H").arg(&h);
    }
    let out = cmd.output().map_err(|e| err(format!("curl spawn failed: {e}")))?;
    let text = String::from_utf8_lossy(&out.stdout);
    let (body, code) = match text.rsplit_once('\n') {
        Some((b, c)) => (b.to_string(), c.trim().parse::<u32>().unwrap_or(0)),
        None => (text.to_string(), 0),
    };
    require_2xx(code, &body)?;
    Ok(json!({"deleted": true, "container": container, "blob": blob, "status": code}))
}

// ---------------------------------------------------------------------------
// cosmos
// ---------------------------------------------------------------------------

/// `cosmos query` -- POST /providers/Microsoft.ResourceGraph/resources with
/// {"query": ...} on the egress plane.
pub fn cosmos_query(inputs: Map<String, Value>) -> Result<Value> {
    let query = get_str(&inputs, "query")?;
    let url = format!("{}/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01", egress_url());
    let mut hdrs = vec!["Content-Type: application/json".to_string()];
    hdrs.extend(auth_header());
    let payload = serde_json::to_string(&json!({ "query": query, "subscriptions": [] }))
        .map_err(|e| err(format!("encode: {e}")))?;
    let (code, body) = http("POST", &url, &hdrs, Some(&payload), None)?;
    require_2xx(code, &body)?;
    serde_json::from_str(&body).map_err(|e| err(format!("bad JSON: {e}")))
}

// ---------------------------------------------------------------------------
// sb
// ---------------------------------------------------------------------------

/// `sb peek` -- GET /topics/:topic/events.
pub fn sb_peek(inputs: Map<String, Value>) -> Result<Value> {
    let topic = get_str(&inputs, "topic")?;
    let url = format!("{}/topics/{}/events", egress_url(), topic);
    let (code, body) = http("GET", &url, &auth_header(), None, None)?;
    require_2xx(code, &body)?;
    serde_json::from_str(&body).map_err(|e| err(format!("bad JSON: {e}")))
}

// ---------------------------------------------------------------------------
// doctor / court (process proxies)
// ---------------------------------------------------------------------------

/// `doctor run` -- proxy to scripts/doctor.py via python3.
pub fn doctor_run(_inputs: Map<String, Value>) -> Result<Value> {
    let script = format!("{}/scripts/doctor.py", repo_root());
    let (code, text) = run_process("python3", &[&script], Some(&repo_root()))?;
    print!("{text}");
    if code == 0 {
        Ok(json!({"doctor": "pass", "exit": 0}))
    } else {
        Err(err(format!("doctor failed (exit {code})")))
    }
}

/// `court run` -- proxy to `just court` via std::process.
pub fn court_run(_inputs: Map<String, Value>) -> Result<Value> {
    let (code, text) = run_process("just", &["court"], Some(&repo_root()))?;
    print!("{text}");
    if code == 0 {
        Ok(json!({"court": "pass", "exit": 0}))
    } else {
        Err(err(format!("court failed (exit {code})")))
    }
}
