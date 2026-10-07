// Created with AI assistance by Claude Code (model: Claude Opus 5.5, model id: claude-opus-5-5, Anthropic).
//
// Evidence collector: links injected fault, Guardian events and diagnostics into a verdict.
//
// SKELETON: this binary only exists so the service has a place in the
// repository, the image build and the documentation. It does nothing yet.
//
// To be implemented:
//   - collect Guardian events (see battery-thermal-guardian/src/bin/guardian_monitor.rs)
//   - read the matching fault records over SOVD REST (GET /sovd/v1/components/battery/faults)
//   - correlate them by correlation id and write PASS / FAIL / INCONCLUSIVE with evidence links

fn main() {
    eprintln!("evidence-collector: not implemented yet (skeleton)");
}
