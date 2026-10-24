#!/bin/sh
# Runs every scenario in contract/scenarios/ headless through ScenarioWorld (the app's own
# GhostCorePipeline, seeded radio and GNSS noise) and prints one line per expectation:
#   scenario|<engines: baseline | ghostcore>|<id>|<expectation>|PASS / FAIL / PENDING [(not gating)]|<claim>|<measured, synthetic>
# Exits non-zero when a gating expectation fails. PENDING means the engine the claim needs has not
# been wired yet; it is never counted as a pass. All numbers are synthetic, not field results.
set -eu
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
out=$(mktemp "${TMPDIR:-/tmp}/ghostcore-scenarios.XXXXXX")
status=0
(cd "$root/ios/MeshCore" && swift test --filter ScenarioTests) >"$out" 2>&1 || status=$?
grep '^scenario|' "$out" || true
if [ "$status" -ne 0 ]; then
  grep -E 'error|failed' "$out" | head -20
  echo "scenarios: gating expectation failed (log: $out)"
  exit "$status"
fi
printf 'scenarios: %s pass, %s fail (not gating), %s pending\n' \
  "$(grep -c '^scenario|.*|PASS' "$out")" "$(grep -c '^scenario|.*|FAIL' "$out")" "$(grep -c '^scenario|.*|PENDING' "$out")"
rm -f "$out"
