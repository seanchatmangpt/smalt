//! Typed noun-verb routes GENERATED from first-class RDF arguments.
//!
//! Every body closes through `BehaviorSpec`, except commands carrying the
//! explicit, admitted `cnv:CustomBehavior` opt-out, which route to a
//! hand-written `crate::custom_handlers::<noun>_<verb>` function instead. That
//! is the sole consumer handler seam this compiler ever emits, and it is
//! visible per-command in the source ontology, not a blanket escape hatch.

use clap_noun_verb::{NounVerbError, Result};
use clap_noun_verb_macros::verb;
use serde::Serialize;
use serde_json::{Map, Value};
#[doc = "Delete a blob (DELETE /{account}/{container}/{blob})."]
#[doc = ""]
#[doc = "# Arguments"]
/// * `container` - Generated argument metadata.
/// * `blob_name` - Generated argument metadata.
#[verb("delete", "blob")]
fn blob_delete(
    #[arg(help = "Container name.", index = 1)] container: String,
    #[arg(help = "Blob name.", index = 2)] blob_name: String,
) -> Result<Value> {
    let mut inputs = Map::new();
    inputs.insert(
        "container".to_owned(),
        encode_input("container", &container)?,
    );
    inputs.insert(
        "blob_name".to_owned(),
        encode_input("blob_name", &blob_name)?,
    );
    crate::custom_handlers::blob_delete(inputs)
}

#[doc = "Get a blob and print its body."]
#[doc = ""]
#[doc = "# Arguments"]
/// * `container` - Generated argument metadata.
/// * `blob_name` - Generated argument metadata.
#[verb("get", "blob")]
fn blob_get(
    #[arg(help = "Container name.", index = 1)] container: String,
    #[arg(help = "Blob name.", index = 2)] blob_name: String,
) -> Result<Value> {
    let mut inputs = Map::new();
    inputs.insert(
        "container".to_owned(),
        encode_input("container", &container)?,
    );
    inputs.insert(
        "blob_name".to_owned(),
        encode_input("blob_name", &blob_name)?,
    );
    crate::custom_handlers::blob_get(inputs)
}

#[doc = "List containers, or blobs in a container."]
#[doc = ""]
#[doc = "# Arguments"]
/// * `container` - Generated argument metadata.
#[verb("list", "blob")]
fn blob_list(
    #[arg(help = "Container name (omit to list containers).", index = 1)] container: Option<String>,
) -> Result<Value> {
    let mut inputs = Map::new();
    if let Some(value) = container {
        inputs.insert("container".to_owned(), encode_input("container", &value)?);
    }
    crate::custom_handlers::blob_list(inputs)
}

#[doc = "Upload a file as a blob (PUT /{account}/{container}/{blob})."]
#[doc = ""]
#[doc = "# Arguments"]
/// * `container` - Generated argument metadata.
/// * `blob_name` - Generated argument metadata.
/// * `file` - Generated argument metadata.
#[verb("put", "blob")]
fn blob_put(
    #[arg(help = "Container name.", index = 1)] container: String,
    #[arg(help = "Blob name.", index = 2)] blob_name: String,
    #[arg(help = "Local file to upload.", index = 3)] file: std::path::PathBuf,
) -> Result<Value> {
    let mut inputs = Map::new();
    inputs.insert(
        "container".to_owned(),
        encode_input("container", &container)?,
    );
    inputs.insert(
        "blob_name".to_owned(),
        encode_input("blob_name", &blob_name)?,
    );
    inputs.insert("file".to_owned(), encode_input("file", &file)?);
    crate::custom_handlers::blob_put(inputs)
}

#[doc = "Run a ResourceGraph query (POST /providers/Microsoft.ResourceGraph/resources)."]
#[doc = ""]
#[doc = "# Arguments"]
/// * `query` - Generated argument metadata.
#[verb("query", "cosmos")]
fn cosmos_query(#[arg(help = "Query text.", index = 1)] query: String) -> Result<Value> {
    let mut inputs = Map::new();
    inputs.insert("query".to_owned(), encode_input("query", &query)?);
    crate::custom_handlers::cosmos_query(inputs)
}

#[doc = "Run the full admission court (just court)."]
#[verb("run", "court")]
fn court_run() -> Result<Value> {
    let inputs = Map::new();
    crate::custom_handlers::court_run(inputs)
}

#[doc = "Run scripts/doctor.py via python3."]
#[verb("run", "doctor")]
fn doctor_run() -> Result<Value> {
    let inputs = Map::new();
    crate::custom_handlers::doctor_run(inputs)
}

#[doc = "Create a key (POST /keys/:name/create)."]
#[doc = ""]
#[doc = "# Arguments"]
/// * `release_policy` - Generated argument metadata.
/// * `name` - Generated argument metadata.
#[verb("create", "kv")]
fn kv_create(
    #[arg(help = "Optional release policy JSON (makes the key exportable).")]
    release_policy: Option<String>,
    #[arg(help = "Key name.", index = 1)] name: String,
) -> Result<Value> {
    let mut inputs = Map::new();
    if let Some(value) = release_policy {
        inputs.insert(
            "release_policy".to_owned(),
            encode_input("release_policy", &value)?,
        );
    }
    inputs.insert("name".to_owned(), encode_input("name", &name)?);
    crate::custom_handlers::kv_create(inputs)
}

#[doc = "Get a key (GET /keys/:name)."]
#[doc = ""]
#[doc = "# Arguments"]
/// * `name` - Generated argument metadata.
#[verb("get", "kv")]
fn kv_get(#[arg(help = "Key name.", index = 1)] name: String) -> Result<Value> {
    let mut inputs = Map::new();
    inputs.insert("name".to_owned(), encode_input("name", &name)?);
    crate::custom_handlers::kv_get(inputs)
}

#[doc = "List keys (GET /keys)."]
#[verb("list", "kv")]
fn kv_list() -> Result<Value> {
    let inputs = Map::new();
    crate::custom_handlers::kv_list(inputs)
}

#[doc = "Release a key (POST /keys/:name/release)."]
#[doc = ""]
#[doc = "# Arguments"]
/// * `name` - Generated argument metadata.
#[verb("release", "kv")]
fn kv_release(#[arg(help = "Key name.", index = 1)] name: String) -> Result<Value> {
    let mut inputs = Map::new();
    inputs.insert("name".to_owned(), encode_input("name", &name)?);
    crate::custom_handlers::kv_release(inputs)
}

#[doc = "Peek events for a topic (GET /topics/:topic/events)."]
#[doc = ""]
#[doc = "# Arguments"]
/// * `topic` - Generated argument metadata.
#[verb("peek", "sb")]
fn sb_peek(#[arg(help = "Topic name.", index = 1)] topic: String) -> Result<Value> {
    let mut inputs = Map::new();
    inputs.insert("topic".to_owned(), encode_input("topic", &topic)?);
    crate::custom_handlers::sb_peek(inputs)
}

#[doc = "Fetch GET /subscriptions and /metadata/endpoints."]
#[verb("list", "status")]
fn status_list() -> Result<Value> {
    let inputs = Map::new();
    crate::custom_handlers::status_list(inputs)
}

#[linkme::distributed_slice(::clap_noun_verb::cli::registry::__NOUN_REGISTRY)]
static REGISTER_BLOB_NOUN: fn() = register_blob_noun;

fn register_blob_noun() {
    ::clap_noun_verb::cli::registry::CommandRegistry::register_noun(
        "blob",
        "Immutable blob storage: put, get, list, delete.",
    );
}

#[linkme::distributed_slice(::clap_noun_verb::cli::registry::__NOUN_REGISTRY)]
static REGISTER_COSMOS_NOUN: fn() = register_cosmos_noun;

fn register_cosmos_noun() {
    ::clap_noun_verb::cli::registry::CommandRegistry::register_noun(
        "cosmos",
        "Cosmos / ResourceGraph query surface.",
    );
}

#[linkme::distributed_slice(::clap_noun_verb::cli::registry::__NOUN_REGISTRY)]
static REGISTER_COURT_NOUN: fn() = register_court_noun;

fn register_court_noun() {
    ::clap_noun_verb::cli::registry::CommandRegistry::register_noun(
        "court",
        "Full admission court: proxy to just court.",
    );
}

#[linkme::distributed_slice(::clap_noun_verb::cli::registry::__NOUN_REGISTRY)]
static REGISTER_DOCTOR_NOUN: fn() = register_doctor_noun;

fn register_doctor_noun() {
    ::clap_noun_verb::cli::registry::CommandRegistry::register_noun(
        "doctor",
        "Runtime preflight: proxy to scripts/doctor.py.",
    );
}

#[linkme::distributed_slice(::clap_noun_verb::cli::registry::__NOUN_REGISTRY)]
static REGISTER_KV_NOUN: fn() = register_kv_noun;

fn register_kv_noun() {
    ::clap_noun_verb::cli::registry::CommandRegistry::register_noun(
        "kv",
        "Key Vault surface: create, get, release, list keys.",
    );
}

#[linkme::distributed_slice(::clap_noun_verb::cli::registry::__NOUN_REGISTRY)]
static REGISTER_SB_NOUN: fn() = register_sb_noun;

fn register_sb_noun() {
    ::clap_noun_verb::cli::registry::CommandRegistry::register_noun(
        "sb",
        "Event Hubs surface: peek events.",
    );
}

#[linkme::distributed_slice(::clap_noun_verb::cli::registry::__NOUN_REGISTRY)]
static REGISTER_STATUS_NOUN: fn() = register_status_noun;

fn register_status_noun() {
    ::clap_noun_verb::cli::registry::CommandRegistry::register_noun(
        "status",
        "Substrate status: subscriptions and metadata endpoints.",
    );
}

#[allow(dead_code)]
fn encode_input<T: Serialize>(name: &str, value: &T) -> Result<Value> {
    serde_json::to_value(value).map_err(|error| {
        NounVerbError::execution_error(format!(
            "failed to encode generated argument {name:?}: {error}"
        ))
    })
}

#[cfg(test)]
mod generated_route_proofs {
    const GENERATED_SOURCE: &str =
        include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/generated_cli.rs"));

    fn routes_only() -> &'static str {
        GENERATED_SOURCE
            .split("#[cfg(test)]")
            .next()
            .unwrap_or(GENERATED_SOURCE)
    }

    #[test]
    fn every_admitted_command_became_one_registered_verb() {
        assert_eq!(routes_only().matches("#[verb(").count(), 13);
    }

    #[test]
    fn no_consumer_handler_seam_survives_generation() {
        // `custom_handlers::` is the sole, explicitly admitted escape hatch
        // (cnv:CustomBehavior); strip it before checking for the legacy,
        // unbounded `handlers::` seam this compiler never emits otherwise.
        let without_admitted_custom_seam = routes_only().replace("custom_handlers::", "");
        assert!(!without_admitted_custom_seam.contains("handlers::"));
        assert!(!routes_only().contains("todo!"));
        assert!(!routes_only().contains("unimplemented!"));
    }

    #[test]
    fn every_custom_command_routes_to_its_own_handler() {
        // Proves per-command wiring, not just that a seam exists somewhere:
        // each cnv:CustomBehavior command must call the one handler function
        // named after ITS OWN noun and verb, not a neighboring command's.
        assert!(
            routes_only().contains("custom_handlers::blob_delete("),
            "blob delete must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::blob_get("),
            "blob get must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::blob_list("),
            "blob list must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::blob_put("),
            "blob put must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::cosmos_query("),
            "cosmos query must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::court_run("),
            "court run must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::doctor_run("),
            "doctor run must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::kv_create("),
            "kv create must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::kv_get("),
            "kv get must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::kv_list("),
            "kv list must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::kv_release("),
            "kv release must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::sb_peek("),
            "sb peek must route to its own custom handler"
        );
        assert!(
            routes_only().contains("custom_handlers::status_list("),
            "status list must route to its own custom handler"
        );
    }
}
