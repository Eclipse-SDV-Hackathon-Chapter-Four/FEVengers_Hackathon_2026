// Created with AI assistance (Claude Opus 5.5, Anthropic).
//
// Dummy Battery Thermal Guardian – TEST DRIVER (throwaway)
// --------------------------------------------------------
// Stands in for the real Guardian: instead of monitoring temperature,
// it sets/clears the four Guardian faults on command, using the same
// reporting module (faults.rs) the real Guardian will use.
//
//   dummy-guardian scenario      walk through all 4 faults: set, wait, clear
//   dummy-guardian interactive   read commands from stdin:
//                                  set <fault> | clear <fault> | status | quit
//
// <fault> = connection_lost | out_of_range | stuck | spike
//
// Both modes keep one FaultApi connection alive for the whole run,
// like the real Guardian.

mod faults;

use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::thread::sleep;
use std::time::Duration;

use clap::{Parser, Subcommand};
use faults::{GuardianFault, GuardianFaults};

#[derive(Parser)]
#[command(about = "Dummy Battery Thermal Guardian: reports Guardian faults to the DFM")]
struct Cli {
    /// Fault catalog (must be the same file the DFM loads)
    #[arg(short, long, default_value = "/catalogs/battery_guardian_catalog.json")]
    catalog: PathBuf,

    #[command(subcommand)]
    mode: Mode,
}

#[derive(Subcommand)]
enum Mode {
    /// Set each fault, hold it, then clear it
    Scenario {
        /// Seconds each fault stays active
        #[arg(long, default_value_t = 5)]
        hold_secs: u64,
    },
    /// Read commands from stdin
    Interactive,
}

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let cli = Cli::parse();

    let mut faults = match GuardianFaults::new(cli.catalog) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };

    match cli.mode {
        Mode::Scenario { hold_secs } => run_scenario(&mut faults, hold_secs),
        Mode::Interactive => run_interactive(&mut faults),
    }

    // Give the fault_lib IPC worker time to flush before FaultApi is dropped.
    sleep(Duration::from_millis(500));
}

fn run_scenario(faults: &mut GuardianFaults, hold_secs: u64) {
    for kind in GuardianFault::ALL {
        println!(">>> {kind}: FAILED (holding {hold_secs} s)");
        faults.set(kind, true);
        sleep(Duration::from_secs(hold_secs));

        println!(">>> {kind}: PASSED");
        faults.set(kind, false);
        sleep(Duration::from_secs(1));
    }
    println!(">>> scenario done");
}

fn run_interactive(faults: &mut GuardianFaults) {
    println!("commands: set <fault> | clear <fault> | status | quit");
    println!("faults:   connection_lost | out_of_range | stuck | spike");

    let stdin = io::stdin();
    loop {
        print!("> ");
        let _ = io::stdout().flush();

        let mut line = String::new();
        if stdin.lock().read_line(&mut line).unwrap_or(0) == 0 {
            break; // EOF
        }
        let words: Vec<&str> = line.split_whitespace().collect();

        match words.as_slice() {
            ["set", name] | ["clear", name] => match GuardianFault::from_short_name(name) {
                Some(kind) => faults.set(kind, words[0] == "set"),
                None => println!("unknown fault '{name}'"),
            },
            ["status"] => {
                for kind in GuardianFault::ALL {
                    let state = if faults.is_active(kind) { "FAILED" } else { "ok" };
                    println!("  {:<16} {state}", kind.short_name());
                }
            }
            ["quit"] | ["exit"] => break,
            [] => {}
            _ => println!("commands: set <fault> | clear <fault> | status | quit"),
        }
    }
}
