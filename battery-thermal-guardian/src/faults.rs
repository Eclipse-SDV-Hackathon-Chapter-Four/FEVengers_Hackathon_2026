// Created with AI assistance (Claude Opus 5.5, Anthropic).
//
// Guardian fault reporting to the DFM (used by dfm.rs)
// ----------------------------------------------------
//
// Responsibilities:
//   * load the fault catalog and connect to the DFM (fault_lib FaultApi)
//   * one fault_lib Reporter per Guardian fault
//   * report only on state CHANGE: Failed when a fault appears,
//     Passed when it clears (the Guardian owns all debouncing)
//   * never panic on a failed report: the safety function must keep
//     running even if the DFM is down
//
// The catalog file must be the same one the DFM loads
// (battery_guardian_catalog.json, catalog id "battery").

use std::fmt;
use std::path::PathBuf;

use common::{
    fault::{FaultId, LifecyclePhase, LifecycleStage},
    ids::SourceId,
    types::MetadataVec,
};
use fault_lib::{
    FaultApi,
    catalog::FaultCatalogBuilder,
    reporter::{Reporter, ReporterApi, ReporterConfig},
    utils::to_static_short_string,
};
use tracing::{error, info};

/// The four Guardian faults. Order and IDs match battery_guardian_catalog.json.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuardianFault {
    /// No temperature sample from the AZ3166 within the timeout.
    ConnectionLost,
    /// Temperature outside the plausible range.
    OutOfRange,
    /// Rolling counter not increasing: the device repeats its last reading.
    Stuck,
    /// Implausible jump between consecutive samples.
    Spike,
}

impl GuardianFault {
    pub const ALL: [GuardianFault; 4] = [
        GuardianFault::ConnectionLost,
        GuardianFault::OutOfRange,
        GuardianFault::Stuck,
        GuardianFault::Spike,
    ];

    /// Fault ID as defined in the catalog.
    pub fn catalog_id(self) -> &'static str {
        match self {
            GuardianFault::ConnectionLost => "btg.src.connection_lost",
            GuardianFault::OutOfRange => "btg.temp.out_of_range",
            GuardianFault::Stuck => "btg.temp.stuck",
            GuardianFault::Spike => "btg.temp.spike",
        }
    }

    /// Short name used on the command line.
    pub fn short_name(self) -> &'static str {
        match self {
            GuardianFault::ConnectionLost => "connection_lost",
            GuardianFault::OutOfRange => "out_of_range",
            GuardianFault::Stuck => "stuck",
            GuardianFault::Spike => "spike",
        }
    }

    pub fn from_short_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|f| f.short_name() == name)
    }

    fn index(self) -> usize {
        self as usize
    }
}

impl fmt::Display for GuardianFault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.catalog_id())
    }
}

/// One reported fault plus its last reported state.
struct TrackedFault {
    kind: GuardianFault,
    reporter: Reporter,
    active: bool,
}

/// Owns the fault library connection and all Guardian reporters.
/// Keep it alive for the whole lifetime of the Guardian.
pub struct GuardianFaults {
    // Must outlive all reporters; dropping it disconnects from the DFM.
    _api: FaultApi,
    // SOVD entity path the faults are stored under (= catalog id).
    path: String,
    faults: Vec<TrackedFault>,
}

impl GuardianFaults {
    /// Load the catalog, connect to the DFM and create the reporters.
    ///
    /// Fails if the catalog cannot be read or the DFM does not answer the
    /// catalog handshake (DFM not running, or IPC not shared).
    pub fn new(catalog_path: PathBuf) -> Result<Self, String> {
        let catalog = FaultCatalogBuilder::new()
            .json_file(catalog_path.clone())
            .and_then(|b| b.try_build())
            .map_err(|e| format!("cannot load catalog {}: {e:?}", catalog_path.display()))?;

        let api = FaultApi::try_new(catalog)
            .map_err(|e| format!("cannot connect to DFM (is it running?): {e:?}"))?;

        let path = FaultApi::get_fault_catalog().id.to_string();

        let config = ReporterConfig {
            source: SourceId {
                entity: short("battery-guardian")?,
                ecu: Some(short("HPC")?),
                domain: Some(short("Powertrain")?),
                sw_component: Some(short("BatteryThermalGuardian")?),
                instance: Some(short("0")?),
            },
            lifecycle_phase: LifecyclePhase::Running,
            default_env_data: MetadataVec::new(),
        };

        let mut faults = Vec::with_capacity(GuardianFault::ALL.len());
        for kind in GuardianFault::ALL {
            let id = FaultId::Text(short(kind.catalog_id())?);
            let reporter = Reporter::new(&id, config.clone())
                .map_err(|e| format!("fault {kind} not in catalog: {e:?}"))?;
            faults.push(TrackedFault { kind, reporter, active: false });
        }

        info!("Guardian faults ready (SOVD path '{path}', {} faults)", faults.len());
        Ok(Self { _api: api, path, faults })
    }

    /// Set the CURRENT condition of a fault. Reports only if it changed.
    pub fn set(&mut self, kind: GuardianFault, active: bool) {
        let path = self.path.clone();
        let fault = &mut self.faults[kind.index()];
        if fault.active == active {
            return; // no change, nothing to report
        }

        let stage = if active { LifecycleStage::Failed } else { LifecycleStage::Passed };
        let record = fault.reporter.create_record(stage);
        match fault.reporter.publish(&path, record) {
            Ok(()) => {
                info!("fault {} -> {:?}", fault.kind, stage);
                fault.active = active;
            }
            // Keep running; state stays unchanged so the next call retries.
            Err(e) => error!("fault {} report failed: {e:?}", fault.kind),
        }
    }

    /// Last reported state of a fault.
    pub fn is_active(&self, kind: GuardianFault) -> bool {
        self.faults[kind.index()].active
    }
}

fn short(s: &str) -> Result<common::types::ShortString, String> {
    to_static_short_string(s).map_err(|e| format!("string too long '{s}': {e:?}"))
}
