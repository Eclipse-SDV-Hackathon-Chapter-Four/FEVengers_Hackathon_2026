// Created with AI assistance (Claude Opus 5.5, Anthropic).
//
// Evidence collector for the Battery Thermal Guardian.
//
// Independent observer: it subscribes over uProtocol (Zenoh) to
//   - the Guardian's topics  //*/8002/1/FFFF  (heartbeat, state, fault, mitigation)
//   - the raw VSS samples    //*/8001/1/8001  (what really came in)
// and serves a web page (default port 7700) with a Start / Stop button.
//
// While a run is recording, every fault RAISED or CLEARED by the Guardian
// becomes one evidence row: the sample that triggered it, the sample before
// it (taken from the collector's own copy of the raw stream, not from the
// Guardian), delta, rate, Guardian state and reason.
// On Stop the run is written to <out>/<run-id>/:
//   events.jsonl   every uProtocol message received during the run
//   faults.json    the evidence rows
//   summary.json   counts, duration, SOVD fault list before and after
//   report.md      human-readable table
//
// The Guardian is not changed and does not know about the collector.

use std::collections::{BTreeMap, VecDeque};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use clap::Parser;
use serde::Serialize;
use serde_json::{json, Value};
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};
use tracing::{info, warn};
use up_rust::{UListener, UMessage, UTransport, UUri};
use up_transport_zenoh::{zenoh_config, UPTransportZenoh};

/// Raw samples kept to find the "previous" value of a trigger sample.
const SAMPLE_BUFFER: usize = 500;
/// A heartbeat older than this means the Guardian is considered down.
const HEARTBEAT_TIMEOUT_MS: u64 = 3000;
/// Wait before building a row, so the trigger sample has surely arrived
/// (Zenoh does not keep the order between the VSS and the Guardian topics).
const ROW_DELAY_MS: u64 = 300;

#[derive(Parser, Clone)]
struct Args {
    /// Web UI / REST address.
    #[arg(long, default_value = "0.0.0.0:7700")]
    listen: String,
    /// Folder for the evidence runs.
    #[arg(long, default_value = "/evidence")]
    out: PathBuf,
    /// Zenoh configuration (JSON5). AutoSD needs an IPv4-only listener.
    #[arg(long)]
    zenoh_config: Option<String>,
    /// uProtocol authority of the collector.
    #[arg(long, default_value = "evidence")]
    authority: String,
    /// Guardian topics (FFFF = all resources of entity 8002).
    #[arg(long, default_value = "//*/8002/1/FFFF")]
    guardian_filter: String,
    /// Raw VSS sample topic (VSS uProtocol publisher).
    #[arg(long, default_value = "//*/8001/1/8001")]
    vss_topic: String,
    /// SOVD fault list, read at Start and Stop. Empty string = off.
    #[arg(long, default_value = "http://127.0.0.1:7690/sovd/v1/apps/battery/faults")]
    sovd: String,
    /// Clear the SOVD fault memory when a run starts (DELETE on --sovd).
    #[arg(long)]
    clear_sovd_on_start: bool,
    /// Logo shown in the web UI (png, jpg or svg). Missing file = no logo.
    #[arg(long, default_value = "/etc/evidence-collector/logo.png")]
    logo: PathBuf,
    /// Rows shown in the web UI (newest first).
    #[arg(long, default_value_t = 10)]
    table_rows: usize,
    /// Expected Guardian limits (TOML). Missing = built-in defaults (guardian.toml).
    #[arg(long, default_value = "/etc/evidence-collector/limits.toml")]
    limits: PathBuf,
}

/// Expected limits, held independently of the Guardian (see config/limits.toml).
#[derive(Clone, Serialize, serde::Deserialize)]
#[serde(default)]
struct Limits {
    min_c: f64,
    max_c: f64,
    max_rate_c_per_s: f64,
    stuck_window_ms: u64,
    stale_timeout_ms: u64,
}

impl Default for Limits {
    fn default() -> Self {
        // Defaults of battery-thermal-guardian/config/guardian.toml [signal]
        Limits { min_c: -40.0, max_c: 150.0, max_rate_c_per_s: 10.0, stuck_window_ms: 30000, stale_timeout_ms: 3000 }
    }
}

impl Limits {
    fn load(path: &PathBuf) -> Limits {
        match std::fs::read_to_string(path) {
            Ok(text) => toml::from_str(&text).unwrap_or_else(|e| {
                warn!("cannot parse {}: {e}; using defaults", path.display());
                Limits::default()
            }),
            Err(_) => {
                info!("no limits file {}; using defaults", path.display());
                Limits::default()
            }
        }
    }
}

/// Tolerance for time-based limits (sample rate, clock jitter).
const TIME_TOLERANCE: f64 = 0.9;

// ------------------------------------------------------------------ data

#[derive(Clone, Serialize)]
struct Sample {
    value: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    rolling_counter: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message_id: Option<String>,
    /// When the collector received it (ms since epoch).
    rx_ms: u64,
}

/// One evidence row: a fault raised / cleared or a mitigation requested /
/// released, with the values behind it.
#[derive(Clone, Serialize)]
struct FaultRow {
    n: usize,
    /// "fault" or "mitigation"
    kind: &'static str,
    at_ms: u64,
    seq: Option<u64>,
    /// Fault name (TempSignalStuck, ...) or mitigation action (REDUCE_POWER_MAX_COOLING, ...).
    fault: String,
    catalog_id: Option<String>,
    class: Option<String>,
    /// RAISED / CLEARED (fault) or REQUESTED / RELEASED (mitigation)
    status: String,
    /// Guardian state after the fault was processed.
    state: Option<String>,
    /// Guardian's own explanation.
    detail: String,
    /// "sample" = triggered by an input sample, "timer" = time-driven (e.g. timeout).
    cause: &'static str,
    previous: Option<Sample>,
    current: Option<Sample>,
    delta_c: Option<f64>,
    dt_ms: Option<u64>,
    rate_c_per_s: Option<f64>,
    /// Limit that applies to this fault, e.g. "|rate| <= 10.0 °C/s".
    limit: Option<String>,
    /// What the collector measured against that limit, e.g. "85.0 °C/s".
    measured: Option<String>,
    /// RAISED rows: true = the collector confirms the limit was broken,
    /// false = the collector does not see a violation (Guardian disagrees).
    limit_broken: Option<bool>,
}

struct Run {
    id: String,
    started_ms: u64,
    rows: Vec<FaultRow>,
    raw: Vec<Value>,
    sovd_before: Value,
}

#[derive(Clone, Serialize)]
struct RunSummary {
    id: String,
    dir: String,
    started_ms: u64,
    stopped_ms: u64,
    duration_ms: u64,
    faults: usize,
    raised: usize,
    cleared: usize,
    mitigations: usize,
    messages: usize,
}

/// (fault events, raised, cleared, mitigation events) of a list of rows.
fn counts(rows: &[FaultRow]) -> (usize, usize, usize, usize) {
    let faults = rows.iter().filter(|r| r.kind == "fault").count();
    let raised = rows.iter().filter(|r| r.status == "RAISED").count();
    (faults, raised, faults - raised, rows.len() - faults)
}

#[derive(Default)]
struct Live {
    temp: Option<f64>,
    rolling_counter: Option<u64>,
    sample_rx_ms: Option<u64>,
    state: Option<String>,
    hb_rx_ms: Option<u64>,
    active_faults: Value,
    active_mitigations: Value,
}

struct Inner {
    samples: VecDeque<Sample>,
    live: Live,
    run: Option<Run>,
    last_rows: Vec<FaultRow>,
    last_run: Option<RunSummary>,
}

type Shared = Arc<Mutex<Inner>>;

#[derive(Clone)]
struct App {
    shared: Shared,
    args: Arc<Args>,
    http: reqwest::Client,
}

// ------------------------------------------------------------------ uProtocol input

#[derive(Clone, Copy)]
enum Kind {
    Guardian,
    Vss,
}

struct Incoming {
    kind: Kind,
    resource: Option<u16>,
    message_id: Option<String>,
    payload: Value,
    rx_ms: u64,
}

/// uProtocol listener: only forwards into a channel; all work happens in the
/// processor task on the main runtime.
struct Rx {
    kind: Kind,
    tx: UnboundedSender<Incoming>,
}

#[async_trait]
impl UListener for Rx {
    async fn on_receive(&self, msg: UMessage) {
        let payload = msg
            .payload
            .as_ref()
            .and_then(|p| serde_json::from_slice(p).ok())
            .unwrap_or(Value::Null);
        let _ = self.tx.send(Incoming {
            kind: self.kind,
            resource: msg.source().map(|s| s.resource_id()),
            message_id: msg.id().map(|id| id.to_hyphenated_string()),
            payload,
            rx_ms: now_ms(),
        });
    }
}

fn topic_name(kind: Kind, resource: Option<u16>) -> &'static str {
    match (kind, resource) {
        (Kind::Vss, _) => "vss",
        (Kind::Guardian, Some(0x8001)) => "heartbeat",
        (Kind::Guardian, Some(0x8002)) => "state",
        (Kind::Guardian, Some(0x8003)) => "fault",
        (Kind::Guardian, Some(0x8004)) => "mitigation",
        (Kind::Guardian, _) => "guardian",
    }
}

async fn process(shared: Shared, limits: Arc<Limits>, mut rx: tokio::sync::mpsc::UnboundedReceiver<Incoming>) {
    while let Some(m) = rx.recv().await {
        let topic = topic_name(m.kind, m.resource);
        let mut row_run: Option<(String, &'static str, Option<String>)> = None;
        {
            let mut g = shared.lock().unwrap();
            let state_now = g.live.state.clone();
            if let Some(run) = g.run.as_mut() {
                run.raw.push(json!({
                    "rx_ms": m.rx_ms, "topic": topic,
                    "message_id": m.message_id, "event": m.payload,
                }));
                if topic == "fault" || topic == "mitigation" {
                    // Mitigation events carry no state: use the Guardian state known now.
                    row_run = Some((run.id.clone(), topic, state_now));
                }
            }
            match topic {
                "vss" => {
                    if let Some(value) = m.payload.get("value").and_then(Value::as_f64) {
                        let s = Sample {
                            value,
                            rolling_counter: m.payload.get("rolling_counter").and_then(Value::as_u64),
                            message_id: m.message_id.clone(),
                            rx_ms: m.rx_ms,
                        };
                        g.live.temp = Some(value);
                        g.live.rolling_counter = s.rolling_counter;
                        g.live.sample_rx_ms = Some(m.rx_ms);
                        g.samples.push_back(s);
                        while g.samples.len() > SAMPLE_BUFFER {
                            g.samples.pop_front();
                        }
                    }
                }
                "heartbeat" => {
                    g.live.hb_rx_ms = Some(m.rx_ms);
                    g.live.state = m.payload.get("state").and_then(Value::as_str).map(str::to_string);
                    g.live.active_faults = m.payload.get("active_faults").cloned().unwrap_or(Value::Null);
                    g.live.active_mitigations =
                        m.payload.get("active_mitigations").cloned().unwrap_or(Value::Null);
                }
                "state" => {
                    g.live.state = m.payload.get("to").and_then(Value::as_str).map(str::to_string);
                }
                _ => {}
            }
        }
        // Fault / mitigation while recording: build the row a moment later (trigger sample may still be in flight).
        if let Some((run_id, kind, state_now)) = row_run {
            let sh = shared.clone();
            let limits = limits.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(ROW_DELAY_MS)).await;
                let mut g = sh.lock().unwrap();
                let row_n = g.run.as_ref().filter(|r| r.id == run_id).map(|r| r.rows.len() + 1);
                if let Some(n) = row_n {
                    let row = build_row(&g.samples, &limits, n, kind, state_now, &m.payload, m.rx_ms);
                    info!(kind, event = %row.fault, status = %row.status, "evidence row {}", n);
                    if let Some(run) = g.run.as_mut() {
                        run.rows.push(row);
                    }
                }
            });
        }
    }
}

/// Finds the triggering sample and the one before it in the collector's own buffer.
fn build_row(
    samples: &VecDeque<Sample>,
    limits: &Limits,
    n: usize,
    kind: &'static str,
    state_now: Option<String>,
    ev: &Value,
    rx_ms: u64,
) -> FaultRow {
    let s = |k: &str| ev.get(k).and_then(Value::as_str).map(str::to_string);
    let trigger = ev.get("trigger").filter(|t| !t.is_null());

    let (current, previous, cause) = match trigger {
        Some(t) => {
            let mid = t.get("message_id").and_then(Value::as_str);
            let rc = t.get("rolling_counter").and_then(Value::as_u64);
            let idx = mid
                .and_then(|id| samples.iter().rposition(|x| x.message_id.as_deref() == Some(id)))
                .or_else(|| rc.and_then(|rc| samples.iter().rposition(|x| x.rolling_counter == Some(rc))));
            match idx {
                Some(i) => (
                    Some(samples[i].clone()),
                    if i > 0 { Some(samples[i - 1].clone()) } else { None },
                    "sample",
                ),
                // Trigger not seen on the raw stream: use the Guardian's copy.
                None => (
                    t.get("value").and_then(Value::as_f64).map(|value| Sample {
                        value,
                        rolling_counter: rc,
                        message_id: mid.map(str::to_string),
                        rx_ms: t.get("sent_ms").and_then(Value::as_u64).unwrap_or(rx_ms),
                    }),
                    samples.back().cloned(),
                    "sample",
                ),
            }
        }
        // Time-driven (e.g. connection lost): last two samples seen before the event.
        None => {
            let before: Vec<&Sample> = samples.iter().filter(|x| x.rx_ms <= rx_ms).collect();
            let k = before.len();
            (
                before.last().map(|x| (*x).clone()),
                if k >= 2 { Some(before[k - 2].clone()) } else { None },
                "timer",
            )
        }
    };

    let (delta_c, dt_ms, rate_c_per_s) = match (&previous, &current) {
        (Some(p), Some(c)) => {
            let d = c.value - p.value;
            let dt = c.rx_ms.saturating_sub(p.rx_ms);
            let rate = if dt > 0 { Some(d / (dt as f64 / 1000.0)) } else { None };
            (Some(d), Some(dt), rate)
        }
        _ => (None, None, None),
    };

    let at_ms = ev.get("at_ms").and_then(Value::as_u64).unwrap_or(rx_ms);
    // FaultEvent: fault / detail / state; MitigationEvent: action / reason (no state).
    let is_mitigation = kind == "mitigation";
    let fault = s(if is_mitigation { "action" } else { "fault" }).unwrap_or_else(|| "?".into());
    let status = s("status").unwrap_or_else(|| "?".into());
    let (limit, measured, broken) = if is_mitigation {
        (None, None, None)
    } else {
        check_limit(&fault, samples, limits, current.as_ref(), rate_c_per_s, at_ms)
    };
    // Only a RAISED row claims a violation; CLEARED shows the values for context.
    let limit_broken = if status == "RAISED" { broken } else { None };

    FaultRow {
        n,
        kind,
        at_ms,
        seq: ev.get("seq").and_then(Value::as_u64),
        fault,
        catalog_id: s("catalog_id"),
        class: s("class"),
        status,
        state: s("state").or(state_now),
        detail: s(if is_mitigation { "reason" } else { "detail" }).unwrap_or_default(),
        cause,
        previous,
        current,
        delta_c,
        dt_ms,
        rate_c_per_s,
        limit,
        measured,
        limit_broken,
    }
}

/// Limit for a catalog fault and what the collector measured on its own copy
/// of the raw stream. Transport faults have no value limit: (None, None, None).
fn check_limit(
    fault: &str,
    samples: &VecDeque<Sample>,
    l: &Limits,
    current: Option<&Sample>,
    rate: Option<f64>,
    at_ms: u64,
) -> (Option<String>, Option<String>, Option<bool>) {
    match fault {
        "TempSignalSpike" => (
            Some(format!("|rate| ≤ {:.1} °C/s", l.max_rate_c_per_s)),
            rate.map(|r| format!("{r:+.1} °C/s")),
            rate.map(|r| r.abs() > l.max_rate_c_per_s),
        ),
        "TempOutOfRange" => (
            Some(format!("{:.1} … {:.1} °C", l.min_c, l.max_c)),
            current.map(|c| format!("{:.2} °C", c.value)),
            current.map(|c| c.value < l.min_c || c.value > l.max_c),
        ),
        "TempSourceConnectionLost" => {
            // Gap between the last sample before the event and the event itself.
            let last = samples.iter().filter(|x| x.rx_ms <= at_ms).last();
            let gap = last.map(|x| at_ms.saturating_sub(x.rx_ms));
            (
                Some(format!("sample every ≤ {} ms", l.stale_timeout_ms)),
                Some(gap.map(|g| format!("no sample for {g} ms")).unwrap_or_else(|| "no sample at all".into())),
                Some(gap.map(|g| g as f64 >= l.stale_timeout_ms as f64 * TIME_TOLERANCE).unwrap_or(true)),
            )
        }
        "TempSignalStuck" => {
            // How long value or rolling counter stayed the same up to the event.
            let before: Vec<&Sample> = samples.iter().filter(|x| x.rx_ms <= at_ms).collect();
            let unchanged_ms = before.last().map(|last| {
                let mut first_value = last.rx_ms;
                let mut first_counter = last.rx_ms;
                for x in before.iter().rev() {
                    if x.value == last.value { first_value = x.rx_ms } else { break }
                }
                for x in before.iter().rev() {
                    if x.rolling_counter.is_some() && x.rolling_counter == last.rolling_counter {
                        first_counter = x.rx_ms
                    } else {
                        break;
                    }
                }
                last.rx_ms.saturating_sub(first_value.min(first_counter))
            });
            (
                Some(format!("changes within {} ms", l.stuck_window_ms)),
                unchanged_ms.map(|u| format!("unchanged for {u} ms")),
                unchanged_ms.map(|u| u as f64 >= l.stuck_window_ms as f64 * TIME_TOLERANCE),
            )
        }
        _ => (None, None, None),
    }
}

// ------------------------------------------------------------------ web

async fn page() -> Html<&'static str> {
    Html(include_str!("../web/index.html"))
}

async fn logo(State(app): State<App>) -> Response {
    let path = &app.args.logo;
    match tokio::fs::read(path).await {
        Ok(bytes) => {
            let ct = match path.extension().and_then(|e| e.to_str()).unwrap_or("") {
                "jpg" | "jpeg" => "image/jpeg",
                "svg" => "image/svg+xml",
                _ => "image/png",
            };
            ([(header::CONTENT_TYPE, ct)], bytes).into_response()
        }
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn status(State(app): State<App>) -> Json<Value> {
    let now = now_ms();
    let g = app.shared.lock().unwrap();
    let rows_src = g.run.as_ref().map(|r| &r.rows).unwrap_or(&g.last_rows);
    let rows: Vec<&FaultRow> = rows_src.iter().rev().take(app.args.table_rows).collect();
    let (faults, raised, cleared, mitigations) = counts(rows_src);
    let hb_age = g.live.hb_rx_ms.map(|t| now.saturating_sub(t));
    Json(json!({
        "now_ms": now,
        "recording": g.run.is_some(),
        "run_id": g.run.as_ref().map(|r| r.id.clone()),
        "started_ms": g.run.as_ref().map(|r| r.started_ms),
        "total": rows_src.len(),
        "faults": faults,
        "raised": raised,
        "cleared": cleared,
        "mitigations": mitigations,
        "rows": rows,
        "live": {
            "temp": g.live.temp,
            "rolling_counter": g.live.rolling_counter,
            "sample_age_ms": g.live.sample_rx_ms.map(|t| now.saturating_sub(t)),
            "state": g.live.state,
            "hb_age_ms": hb_age,
            "guardian_alive": hb_age.map(|a| a < HEARTBEAT_TIMEOUT_MS).unwrap_or(false),
            "active_faults": g.live.active_faults,
            "active_mitigations": g.live.active_mitigations,
        },
        "last_run": g.last_run,
    }))
}

async fn start(State(app): State<App>) -> Response {
    if app.shared.lock().unwrap().run.is_some() {
        return (StatusCode::CONFLICT, Json(json!({"error": "a run is already recording"}))).into_response();
    }
    if app.args.clear_sovd_on_start && !app.args.sovd.is_empty() {
        if let Err(e) = app.http.delete(&app.args.sovd).send().await {
            warn!("SOVD clear failed: {e}");
        }
    }
    let sovd_before = sovd_get(&app).await;
    let started = now_ms();
    let id = format!("run-{}", utc_stamp(started));
    let mut g = app.shared.lock().unwrap();
    if g.run.is_some() {
        return (StatusCode::CONFLICT, Json(json!({"error": "a run is already recording"}))).into_response();
    }
    g.run = Some(Run { id: id.clone(), started_ms: started, rows: Vec::new(), raw: Vec::new(), sovd_before });
    g.last_rows.clear();
    info!(run = %id, "evidence run started");
    Json(json!({"run_id": id, "started_ms": started})).into_response()
}

async fn stop(State(app): State<App>) -> Response {
    if app.shared.lock().unwrap().run.is_none() {
        return (StatusCode::CONFLICT, Json(json!({"error": "no run is recording"}))).into_response();
    }
    // Let rows that are still being built (ROW_DELAY_MS) land in this run.
    tokio::time::sleep(Duration::from_millis(ROW_DELAY_MS + 100)).await;
    let sovd_after = sovd_get(&app).await;
    let Some(run) = app.shared.lock().unwrap().run.take() else {
        return (StatusCode::CONFLICT, Json(json!({"error": "no run is recording"}))).into_response();
    };
    let stopped = now_ms();
    let dir = app.args.out.join(&run.id);
    let (faults, raised, cleared, mitigations) = counts(&run.rows);
    let summary = RunSummary {
        id: run.id.clone(),
        dir: dir.display().to_string(),
        started_ms: run.started_ms,
        stopped_ms: stopped,
        duration_ms: stopped.saturating_sub(run.started_ms),
        faults,
        raised,
        cleared,
        mitigations,
        messages: run.raw.len(),
    };
    if let Err(e) = write_run(&dir, &run, &summary, &sovd_after).await {
        warn!("cannot write evidence to {}: {e}", dir.display());
    } else {
        info!(dir = %dir.display(), faults = run.rows.len(), "evidence run written");
    }
    let mut g = app.shared.lock().unwrap();
    g.last_rows = run.rows;
    g.last_run = Some(summary.clone());
    Json(json!(summary)).into_response()
}

async fn sovd_get(app: &App) -> Value {
    if app.args.sovd.is_empty() {
        return Value::Null;
    }
    match app.http.get(&app.args.sovd).send().await {
        Ok(r) => r.json::<Value>().await.unwrap_or_else(|e| json!({"error": e.to_string()})),
        Err(e) => json!({"error": e.to_string()}),
    }
}

async fn write_run(dir: &PathBuf, run: &Run, summary: &RunSummary, sovd_after: &Value) -> std::io::Result<()> {
    tokio::fs::create_dir_all(dir).await?;
    let mut jsonl = String::new();
    for line in &run.raw {
        jsonl.push_str(&line.to_string());
        jsonl.push('\n');
    }
    tokio::fs::write(dir.join("events.jsonl"), jsonl).await?;
    tokio::fs::write(dir.join("faults.json"), serde_json::to_vec_pretty(&run.rows)?).await?;

    // Per fault: raised / cleared; per mitigation: requested / released.
    let mut per_fault: BTreeMap<&str, (usize, usize)> = BTreeMap::new();
    let mut per_mitigation: BTreeMap<&str, (usize, usize)> = BTreeMap::new();
    for r in &run.rows {
        let map = if r.kind == "mitigation" { &mut per_mitigation } else { &mut per_fault };
        let e = map.entry(r.fault.as_str()).or_default();
        if r.status == "RAISED" || r.status == "REQUESTED" { e.0 += 1 } else { e.1 += 1 }
    }
    let to_json = |m: &BTreeMap<&str, (usize, usize)>, a: &str, b: &str| -> Value {
        m.iter()
            .map(|(k, (x, y))| (k.to_string(), json!({(a): x, (b): y})))
            .collect::<serde_json::Map<_, _>>()
            .into()
    };
    let full = json!({
        "_generated": "Created with AI assistance (Claude Opus 5.5, Anthropic)",
        "run": summary,
        "per_fault": to_json(&per_fault, "raised", "cleared"),
        "per_mitigation": to_json(&per_mitigation, "requested", "released"),
        "sovd_before": run.sovd_before,
        "sovd_after": sovd_after,
    });
    tokio::fs::write(dir.join("summary.json"), serde_json::to_vec_pretty(&full)?).await?;
    tokio::fs::write(dir.join("report.md"), report_md(run, summary)).await?;
    Ok(())
}

fn report_md(run: &Run, s: &RunSummary) -> String {
    let v = |x: &Option<Sample>| x.as_ref().map(|x| format!("{:.2}", x.value)).unwrap_or_else(|| "–".into());
    let f = |x: Option<f64>| x.map(|x| format!("{x:+.2}")).unwrap_or_else(|| "–".into());
    let mut md = format!(
        "# Evidence run {}\n\n> Created with AI assistance (Claude Opus 5.5, Anthropic).\n\n\
         | | |\n|---|---|\n| Start | {} UTC |\n| Duration | {:.1} s |\n| Fault events | {} ({} raised, {} cleared) |\n| Mitigation events | {} |\n| uProtocol messages | {} |\n\n\
         | # | Time (UTC) | Kind | Fault / mitigation | Event | Previous °C | Current °C | Δ °C | Rate °C/s | Limit | Measured | Confirmed | Cause | State | Guardian reason |\n\
         |---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n",
        s.id, utc_stamp(s.started_ms), s.duration_ms as f64 / 1000.0, s.faults, s.raised, s.cleared,
        s.mitigations, s.messages
    );
    for r in &run.rows {
        md.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |\n",
            r.n, utc_stamp(r.at_ms), r.kind, r.fault, r.status, v(&r.previous), v(&r.current),
            f(r.delta_c), f(r.rate_c_per_s),
            r.limit.clone().unwrap_or_else(|| "–".into()),
            r.measured.clone().unwrap_or_else(|| "–".into()),
            match r.limit_broken { Some(true) => "yes", Some(false) => "NO", None => "–" },
            r.cause, r.state.clone().unwrap_or_default(),
            r.detail.replace('|', "/")
        ));
    }
    md
}

// ------------------------------------------------------------------ helpers

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// "20261007-143005" (UTC) from ms since epoch, without a date crate.
fn utc_stamp(ms: u64) -> String {
    let secs = ms / 1000;
    let (h, m, s) = ((secs / 3600) % 24, (secs / 60) % 60, secs % 60);
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = (secs / 86400) as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if mo <= 2 { 1 } else { 0 };
    format!("{y:04}{mo:02}{d:02}-{h:02}{m:02}{s:02}")
}

fn init_logging() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,zenoh=warn"));
    tracing_subscriber::fmt().with_env_filter(filter).with_writer(std::io::stderr).init();
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    init_logging();
    let args = Arc::new(Args::parse());

    let shared: Shared = Arc::new(Mutex::new(Inner {
        samples: VecDeque::new(),
        live: Live::default(),
        run: None,
        last_rows: Vec::new(),
        last_run: None,
    }));

    // uProtocol over Zenoh
    let config = match &args.zenoh_config {
        Some(path) => zenoh_config::Config::from_file(path)?,
        None => zenoh_config::Config::default(),
    };
    let transport = UPTransportZenoh::builder(args.authority.as_str())?
        .with_config(config)
        .build()
        .await?;
    let (tx, rx) = unbounded_channel();
    transport
        .register_listener(
            &UUri::from_str(&args.guardian_filter)?,
            None,
            Arc::new(Rx { kind: Kind::Guardian, tx: tx.clone() }),
        )
        .await?;
    transport
        .register_listener(&UUri::from_str(&args.vss_topic)?, None, Arc::new(Rx { kind: Kind::Vss, tx }))
        .await?;
    let limits = Arc::new(Limits::load(&args.limits));
    info!(limits = %serde_json::to_string(&*limits).unwrap_or_default(), "expected limits");
    tokio::spawn(process(shared.clone(), limits, rx));
    info!(guardian = %args.guardian_filter, vss = %args.vss_topic, "subscribed");

    // Web UI + REST
    let app = App {
        shared,
        args: args.clone(),
        http: reqwest::Client::builder().timeout(Duration::from_secs(3)).build()?,
    };
    let router = Router::new()
        .route("/", get(page))
        .route("/logo", get(logo))
        .route("/api/status", get(status))
        .route("/api/start", post(start))
        .route("/api/stop", post(stop))
        .with_state(app);
    let listener = tokio::net::TcpListener::bind(&args.listen).await?;
    info!(addr = %args.listen, out = %args.out.display(), "evidence collector web UI");
    axum::serve(listener, router)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    drop(transport);
    Ok(())
}
