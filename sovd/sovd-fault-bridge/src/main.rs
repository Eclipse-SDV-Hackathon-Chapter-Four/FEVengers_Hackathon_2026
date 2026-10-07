// Created with AI assistance (Claude Opus 5.5, Anthropic).
//
// SOVD fault bridge
// -----------------
// Eclipse OpenSOVD's DFM (fault-lib, dfm_lib) stores HPC faults and answers
// queries over iceoryx2 ("dfm/query"), but opensovd-core has no /faults route
// yet. This service closes that gap: it maps SOVD REST fault requests onto the
// DFM query API and returns JSON in the same shape the OpenSOVD Classic
// Diagnostic Adapter (CDA) uses, so testers see one consistent format.
//
//   GET    /sovd/v1/components                         -> configured entities
//   GET    /sovd/v1/components/{entity}/faults         -> DfmQueryApi::get_all_faults
//   GET    /sovd/v1/components/{entity}/faults/{code}  -> DfmQueryApi::get_fault
//   DELETE /sovd/v1/components/{entity}/faults         -> DfmQueryApi::delete_all_faults
//   DELETE /sovd/v1/components/{entity}/faults/{code}  -> DfmQueryApi::delete_fault
//   GET    /health                                     -> liveness
//
// {entity} is the SOVD path the reporter publishes under; for fault_lib
// reporters that is the fault catalog id (e.g. "battery", "hvac").

use std::sync::{Arc, Mutex};

use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use clap::Parser;
use dfm_lib::{
    DfmQueryApi, Iceoryx2DfmQuery,
    sovd_fault_manager::{Error as DfmError, SovdFault},
};
use serde_json::{Map, Value, json};
use tracing::{info, warn};

#[derive(Parser, Debug)]
#[command(version, about = "Expose OpenSOVD DFM faults over SOVD REST")]
struct Args {
    /// Address and port to listen on
    #[arg(long, default_value = "0.0.0.0:7691")]
    listen: String,

    /// Entities (fault catalog ids) listed under /sovd/v1/components
    #[arg(long, value_delimiter = ',', default_value = "battery")]
    entities: Vec<String>,

    /// Timeout for one DFM query, in milliseconds
    #[arg(long, default_value_t = 1000)]
    dfm_timeout_ms: u64,
}

#[derive(Clone)]
struct AppState {
    // One iceoryx2 client, used by one request at a time.
    dfm: Arc<Mutex<Iceoryx2DfmQuery>>,
    entities: Arc<Vec<String>>,
}

// ---------- error mapping ----------

struct ApiError(StatusCode, String);

impl From<DfmError> for ApiError {
    fn from(e: DfmError) -> Self {
        match e {
            DfmError::NotFound => ApiError(StatusCode::NOT_FOUND, "not found".into()),
            DfmError::BadArgument => ApiError(StatusCode::BAD_REQUEST, "bad argument".into()),
            // Storage errors include "DFM not reachable" and query timeouts.
            other => ApiError(StatusCode::SERVICE_UNAVAILABLE, other.to_string()),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({ "error_code": self.0.as_u16(), "message": self.1 }))).into_response()
    }
}

// ---------- DFM calls (blocking iceoryx2, run off the async runtime) ----------

async fn with_dfm<T, F>(state: &AppState, f: F) -> Result<T, ApiError>
where
    T: Send + 'static,
    F: FnOnce(&Iceoryx2DfmQuery) -> Result<T, DfmError> + Send + 'static,
{
    let dfm = Arc::clone(&state.dfm);
    tokio::task::spawn_blocking(move || {
        let guard = dfm
            .lock()
            .map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "DFM client poisoned".into()))?;
        f(&guard).map_err(ApiError::from)
    })
    .await
    .map_err(|e| ApiError(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
}

// ---------- JSON mapping (CDA-compatible fault shape) ----------

fn fault_to_json(f: &SovdFault) -> Value {
    let mut obj = Map::new();
    obj.insert("code".into(), json!(f.code));
    obj.insert("display_code".into(), json!(f.display_code));
    obj.insert("scope".into(), json!(f.scope));
    obj.insert("fault_name".into(), json!(f.fault_name));
    obj.insert("severity".into(), json!(f.severity));
    obj.insert("status".into(), status_to_json(f));
    insert_opt(&mut obj, "symptom", f.symptom.as_ref());
    insert_opt(&mut obj, "occurrence_counter", f.occurrence_counter.as_ref());
    insert_opt(&mut obj, "aging_counter", f.aging_counter.as_ref());
    insert_opt(&mut obj, "healing_counter", f.healing_counter.as_ref());
    insert_opt(&mut obj, "first_occurrence", f.first_occurrence.as_ref());
    insert_opt(&mut obj, "last_occurrence", f.last_occurrence.as_ref());
    Value::Object(obj)
}

fn status_to_json(f: &SovdFault) -> Value {
    // Typed status is authoritative when present; field names match CDA FaultStatus.
    if let Some(s) = &f.typed_status {
        let mut obj = Map::new();
        insert_opt(&mut obj, "test_failed", s.test_failed.as_ref());
        insert_opt(&mut obj, "test_failed_this_operation_cycle", s.test_failed_this_operation_cycle.as_ref());
        insert_opt(&mut obj, "pending_dtc", s.pending_dtc.as_ref());
        insert_opt(&mut obj, "confirmed_dtc", s.confirmed_dtc.as_ref());
        insert_opt(&mut obj, "test_not_completed_since_last_clear", s.test_not_completed_since_last_clear.as_ref());
        insert_opt(&mut obj, "test_failed_since_last_clear", s.test_failed_since_last_clear.as_ref());
        insert_opt(&mut obj, "test_not_completed_this_operation_cycle", s.test_not_completed_this_operation_cycle.as_ref());
        insert_opt(&mut obj, "warning_indicator_requested", s.warning_indicator_requested.as_ref());
        insert_opt(&mut obj, "mask", s.mask.as_ref());
        Value::Object(obj)
    } else {
        json!(f.status)
    }
}

fn insert_opt<T: serde::Serialize>(obj: &mut Map<String, Value>, key: &str, v: Option<&T>) {
    if let Some(v) = v {
        obj.insert(key.into(), json!(v));
    }
}

// ---------- handlers ----------

async fn list_components(State(state): State<AppState>) -> Json<Value> {
    let items: Vec<Value> = state
        .entities
        .iter()
        .map(|e| {
            json!({
                "id": e,
                "name": e,
                "href": format!("/sovd/v1/components/{e}"),
                "faults": format!("/sovd/v1/components/{e}/faults"),
            })
        })
        .collect();
    Json(json!({ "items": items }))
}

async fn get_faults(
    State(state): State<AppState>,
    Path(entity): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let faults = with_dfm(&state, move |dfm| dfm.get_all_faults(&entity)).await?;
    Ok(Json(json!({ "items": faults.iter().map(fault_to_json).collect::<Vec<_>>() })))
}

async fn get_fault(
    State(state): State<AppState>,
    Path((entity, code)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    let (fault, env) = with_dfm(&state, move |dfm| dfm.get_fault(&entity, &code)).await?;
    Ok(Json(json!({ "item": fault_to_json(&fault), "environment_data": env })))
}

async fn delete_faults(
    State(state): State<AppState>,
    Path(entity): Path<String>,
) -> Result<StatusCode, ApiError> {
    with_dfm(&state, move |dfm| dfm.delete_all_faults(&entity)).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn delete_fault(
    State(state): State<AppState>,
    Path((entity, code)): Path<(String, String)>,
) -> Result<StatusCode, ApiError> {
    with_dfm(&state, move |dfm| dfm.delete_fault(&entity, &code)).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn health() -> Json<Value> {
    Json(json!({ "status": "ok" }))
}

// ---------- main ----------

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let args = Args::parse();

    // open_or_create on the DFM side means the bridge may start before the DFM.
    let dfm = Iceoryx2DfmQuery::with_timeout(std::time::Duration::from_millis(args.dfm_timeout_ms))
        .unwrap_or_else(|e| panic!("cannot open DFM query service 'dfm/query': {e}"));

    let state = AppState {
        dfm: Arc::new(Mutex::new(dfm)),
        entities: Arc::new(args.entities.clone()),
    };

    let app = Router::new()
        .route("/health", get(health))
        .route("/sovd/v1/components", get(list_components))
        .route(
            "/sovd/v1/components/{entity}/faults",
            get(get_faults).delete(delete_faults),
        )
        .route(
            "/sovd/v1/components/{entity}/faults/{code}",
            get(get_fault).delete(delete_fault),
        )
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(&args.listen)
        .await
        .unwrap_or_else(|e| panic!("cannot bind {}: {e}", args.listen));
    info!("SOVD fault bridge listening on {} (entities: {:?})", args.listen, args.entities);

    if let Err(e) = axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
    {
        warn!("server stopped: {e}");
    }
}
