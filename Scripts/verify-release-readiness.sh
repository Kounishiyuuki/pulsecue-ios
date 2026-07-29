#!/usr/bin/env bash
#
# verify-release-readiness.sh
#
# Fast, local pre-submission checks for PulseCue. Concise pass/fail output —
# no full build logs. Run from the repository root.
#
#   ./Scripts/verify-release-readiness.sh          # fast checks only
#   ./Scripts/verify-release-readiness.sh --full    # + Debug/Release builds
#
# It is intentionally small: it verifies release-safety invariants, not a CI
# system. Manual TestFlight/App Store steps live in Docs/testflight-checklist.md
# and Docs/release-process.md.
#
set -uo pipefail

PROJECT="Pulse Cue.xcodeproj"
APP_SRC="Pulse Cue"
SCHEME="Pulse Cue"
fail=0

pass() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

hdr "1. Project parses"
if xcodebuild -list -project "$PROJECT" >/dev/null 2>&1; then
  pass "xcodebuild -list"
else
  bad "xcodebuild -list failed (project does not parse)"
fi
if plutil -lint "$PROJECT/project.pbxproj" >/dev/null 2>&1; then
  pass "pbxproj is valid"
else
  bad "pbxproj plutil -lint failed"
fi

hdr "2. Info.plist and privacy manifest"
for f in "$APP_SRC/Info.plist" "$APP_SRC/PrivacyInfo.xcprivacy" "$APP_SRC/Pulse_Cue.entitlements"; do
  if [ -f "$f" ] && plutil -lint "$f" >/dev/null 2>&1; then
    pass "$(basename "$f") present and valid"
  else
    bad "$(basename "$f") missing or invalid"
  fi
done

hdr "3. App icon present"
ICON_DIR=$(find "$APP_SRC" -type d -name "AppIcon.appiconset" | head -1)
if [ -n "$ICON_DIR" ] && ls "$ICON_DIR"/*.png >/dev/null 2>&1; then
  pass "AppIcon.appiconset has image(s)"
else
  bad "AppIcon.appiconset missing image(s) (App Store blocker)"
fi

hdr "4. DEBUG QA fixtures are #if DEBUG gated in app source"
# Each app-source line that references a QA/fixture launch argument must sit in
# a file that also compiles it under DEBUG. Heuristic: flag any *.swift under
# the app source that uses a fixture argument constant without a nearby #if
# DEBUG in the same file.
qa_leak=0
while IFS= read -r sfile; do
  if rg -q "customMachineFlowArgument|glassUIRouteArgument|formGuide3DArgument|requestedGlassUIRoute|isFormGuideDebugRoute" "$sfile"; then
    if ! rg -q "#if DEBUG" "$sfile"; then
      bad "QA fixture referenced without #if DEBUG in: $sfile"
      qa_leak=1
    fi
  fi
done < <(git ls-files "$APP_SRC" | rg '\.swift$')
[ "$qa_leak" -eq 0 ] && pass "no ungated QA fixture usage in app source"

hdr "5. Secret / endpoint scan (application-owned, excluding DEBUG + tests + docs)"
# Application source only. Loopback + fake tokens live in #if DEBUG blocks and
# are excluded by design; a hit here is a real finding.
SECRET_HITS=$(git ls-files "$APP_SRC" | rg '\.(swift|plist|entitlements|xcprivacy)$' \
  | tr '\n' '\0' \
  | xargs -0 rg -n --no-heading \
      -e 'sk-[A-Za-z0-9]{20,}' \
      -e 'AIza[0-9A-Za-z_-]{30,}' \
      -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
      -e '[a-z0-9]+\.workers\.dev' \
      2>/dev/null | rg -v 'YOUR_IOS_CLIENT_ID' || true)
if [ -z "$SECRET_HITS" ]; then
  pass "no hardcoded keys / private keys / workers.dev endpoints"
else
  bad "possible secret/endpoint (inspect manually, do not paste):"
  echo "$SECRET_HITS" | sed 's/=.*/= <redacted>/' | head -5
fi

hdr "6. Working tree hygiene"
if git diff --check >/dev/null 2>&1; then
  pass "git diff --check clean (no conflict markers / whitespace errors)"
else
  bad "git diff --check reported issues"
fi

if [ "${1:-}" = "--full" ]; then
  DEST="${PULSECUE_SIM_DEST:-platform=iOS Simulator,name=iPhone 16 Pro}"
  hdr "7. Debug build"
  if xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
      -destination "$DEST" CODE_SIGNING_ALLOWED=NO >/dev/null 2>&1; then
    pass "Debug build succeeded"
  else
    bad "Debug build failed"
  fi
  hdr "8. Release build (signing disabled)"
  if xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
      -destination "$DEST" CODE_SIGNING_ALLOWED=NO >/dev/null 2>&1; then
    pass "Release build succeeded"
  else
    bad "Release build failed"
  fi
else
  warn "builds skipped (pass --full to run Debug + Release builds)"
fi

hdr "Result"
if [ "$fail" -eq 0 ]; then
  printf '\033[32mAll release-readiness checks passed.\033[0m\n'
  exit 0
else
  printf '\033[31mOne or more checks failed — see FAIL lines above.\033[0m\n'
  exit 1
fi
