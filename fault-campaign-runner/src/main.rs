// Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
//
// Fault campaign runner: runs repeatable fault scenarios against the Guardian.
//
// SKELETON: this binary only exists so the service has a place in the
// repository, the image build and the documentation. It does nothing yet.
//
// To be implemented:
//   - read a campaign file (scenario, fault class, start/end time, correlation id)
//   - inject the fault into the VSS stream (see battery-thermal-guardian/src/bin/vss_sim.rs)
//   - record when each fault was injected, for the detection latency

fn main() {
    eprintln!("fault-campaign-runner: not implemented yet (skeleton)");
}
