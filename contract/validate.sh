#!/bin/sh
# GhostCore merge gate (see ARCHITECTURE.md, "Merge gate"). Run from anywhere in the repository:
#   contract/validate.sh           every check, including the unsigned iOS app build
#   contract/validate.sh --quick   skip the iOS app build
# Stops at the first failing check and exits non-zero. Logs go to $GHOSTCORE_LOGS (default: a temp dir).
# Nothing here touches a phone, signs a build or uploads anything.
set -eu

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
logs=${GHOSTCORE_LOGS:-$(mktemp -d "${TMPDIR:-/tmp}/ghostcore-gate.XXXXXX")}
mkdir -p "$logs"
quick=0
[ "${1:-}" = "--quick" ] && quick=1

step() {
  name=$1
  shift
  printf '%-44s' "$name"
  log="$logs/$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '-').log"
  start=$(date +%s)
  if (cd "$root" && "$@") >"$log" 2>&1; then
    echo "ok ($(( $(date +%s) - start )) s)"
  else
    echo "FAILED, see $log"
    tail -20 "$log"
    exit 1
  fi
}

website_deps() {
  [ -d website/node_modules ] || (cd website && npm ci --no-audit --no-fund)
}

ios_build() {
  cd ios
  xcodegen
  xcodebuild -project MeshMapper.xcodeproj -scheme MeshMapper -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$logs/DerivedData" CODE_SIGNING_ALLOWED=NO build
}

echo "GhostCore gate on $(git -C "$root" rev-parse --abbrev-ref HEAD) $(git -C "$root" rev-parse --short HEAD); logs in $logs"
step "MeshCore unit tests (swift test)" sh -c 'cd ios/MeshCore && swift test'
step "Website dependencies" website_deps
step "Contract fixtures (TypeScript mirror)" sh -c 'cd website && npx tsx scripts/ghostcore-check.ts'
step "Website typecheck" sh -c 'cd website && npm run typecheck'
step "Signal map check (TypeScript, golden)" sh -c 'cd website && npx tsx scripts/signalmap-check.ts'
step "Movement model golden v1 (JS runtime)" node ml/runtime/test-golden.mjs
step "Movement model golden v2 (JS runtime)" node ml/runtime/test-golden-v2.mjs
step "Route model golden (JS runtime)" node ml/runtime/test-golden-routes.mjs
step "Route filter golden (JS runtime)" node ml/runtime/test-golden-filter.mjs
if [ -x "$root/contract/scenarios/run.sh" ]; then
  step "GPS outage/spoofing scenarios" "$root/contract/scenarios/run.sh"
fi
if [ "$quick" = 0 ]; then
  step "iOS app build (unsigned, generic iOS)" ios_build
fi
echo "GhostCore gate passed"
