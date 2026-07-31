#!/usr/bin/env bash
#
# capture-ui-inventory.sh
#
# Deterministic DEBUG-only UI inventory capture for design review / Stitch.
# Reuses the GlassUI visual-QA routes (all `#if DEBUG`). Generated images are
# LOCAL artifacts under an ignored build dir — never committed.
#
#   ./Scripts/capture-ui-inventory.sh [--device <PRIMARY_UDID>] \
#       [--narrow-device <NARROW_UDID>] [--output <dir>] \
#       [--variant light|dark|narrow|all] [--group <NN>] [--force]
#
# Variants (Slice 5):
#   light  — all canonical routes, light appearance, primary device (the 25
#            canonical images).
#   dark   — the selected DARK_VARIANTS only, dark appearance, primary device.
#   narrow — the selected NARROW_VARIANTS only, light appearance, narrow device.
#   all    — canonical + selected dark + selected narrow (final full capture).
#
# Appearance architecture (audited Slice 5): the app has NO app-wide appearance
# setting and follows the system; only RunnerView forces `.dark`. So dark
# variants are meaningful for non-Runner screens, and a Runner dark variant is
# redundant (already dark in the light run) — it is intentionally excluded.
#
set -uo pipefail

PROJECT="Pulse Cue.xcodeproj"
SCHEME="Pulse Cue"
BUNDLE_ID="com.kounishiyuuki.pulsecue"
ROUTE_ARG="-pulsecue-debug-glass-ui-route"
SCREENSHOT_DEFAULTS_DOMAIN="com.pulsecue.screenshot-visualqa"

DEVICE=""
NARROW_DEVICE=""
OUTPUT="build/ui-inventory"
VARIANT="light"
GROUP=""
FORCE=0
SETTLE="${PULSECUE_SETTLE:-4}"
FORMGUIDE_DELAY="${PULSECUE_FORMGUIDE_DELAY:-3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --narrow-device) NARROW_DEVICE="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    --all) shift ;;                    # accepted for symmetry; default is all
    --force) FORCE=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

fail() { printf '\033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
info() { printf '\033[1m%s\033[0m\n' "$1"; }

command -v xcrun >/dev/null 2>&1 || fail "xcrun not found"
[ -d "$PROJECT" ] || fail "run from the repository root ($PROJECT not found)"

# Resolve a full device UDID: prefer a booted device; else the first available
# device whose name contains $1 (a name hint, e.g. "iPhone SE"). Never a prefix.
resolve_device_by_name() {
  local hint="$1"
  xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import sys, json
hint = sys.argv[1]
d = json.load(sys.stdin)["devices"]
cands = [x for v in d.values() for x in v if x.get("isAvailable", True)]
booted = [x for x in cands if x.get("state") == "Booted" and hint in x["name"]]
named  = [x for x in cands if hint in x["name"]]
pick = (booted or named)
print(pick[0]["udid"] if pick else "")
' "$hint" 2>/dev/null
}

if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun simctl list devices booted -j 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin)["devices"];print(next((x["udid"] for v in d.values() for x in v if x.get("state")=="Booted"),""))' 2>/dev/null)
fi
[ -n "$DEVICE" ] || fail "no --device UDID and no booted simulator"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" 2>/dev/null

NEEDS_NARROW=0
case "$VARIANT" in narrow|all) NEEDS_NARROW=1 ;; esac
if [ "$NEEDS_NARROW" -eq 1 ]; then
  if [ -z "$NARROW_DEVICE" ]; then
    NARROW_DEVICE=$(resolve_device_by_name "iPhone SE")
  fi
  [ -n "$NARROW_DEVICE" ] || fail "variant '$VARIANT' needs a narrow device: pass --narrow-device <UDID> (no iPhone SE found)"
  xcrun simctl bootstatus "$NARROW_DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$NARROW_DEVICE" 2>/dev/null
fi

info "Primary: $DEVICE  Narrow: ${NARROW_DEVICE:-none}  Variant: $VARIANT"

reset_device() {
  local dev="$1"
  [ -n "$dev" ] || return 0
  xcrun simctl terminate "$dev" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl status_bar "$dev" clear >/dev/null 2>&1 || true
  xcrun simctl spawn "$dev" defaults delete "$SCREENSHOT_DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
  # Restore a neutral (light) appearance; never touch the host macOS appearance.
  xcrun simctl ui "$dev" appearance light >/dev/null 2>&1 || true
}
cleanup() { reset_device "$DEVICE"; reset_device "$NARROW_DEVICE"; }
trap cleanup EXIT

info "Building Debug app…"
xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
  -destination "id=$DEVICE" -configuration Debug CODE_SIGNING_ALLOWED=NO >/dev/null 2>&1 \
  || fail "Debug build failed"
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Pulse_Cue-*/Build/Products/Debug-iphonesimulator/"Pulse Cue.app" 2>/dev/null | head -1)
[ -n "$APP" ] || fail "built app not found"
xcrun simctl install "$DEVICE" "$APP" || fail "install failed (primary)"
if [ "$NEEDS_NARROW" -eq 1 ]; then
  xcrun simctl install "$NARROW_DEVICE" "$APP" || fail "install failed (narrow)"
fi

apply_appearance() {
  local dev="$1" appearance="$2"
  xcrun simctl ui "$dev" appearance "$appearance" >/dev/null 2>&1 || true
  xcrun simctl ui "$dev" content_size medium >/dev/null 2>&1 || true
  xcrun simctl status_bar "$dev" override \
    --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
}

# group | filename-stem | route  (canonical: light, primary device)
ROUTES="
01-onboarding|onboarding|onboarding
02-auth|login|login
03-home|home|home
05-planner|target-body-part|planner
05-planner|preview-single|preview-single
05-planner|weekly-before-generation|preview-weekly-before-generation
05-planner|weekly-candidate|preview-weekly
05-planner|unavailable-target|planner-unavailable-target
06-runner|runner-active|runner-active
06-runner|runner-active-later-set|runner-active-later-set
06-runner|runner-rest|runner-rest
07-history|history-populated|history-populated
07-history|history-detail|history-detail
08-my-gym|mygym-active|mygym-active
08-my-gym|mygym-empty|mygym-empty
08-my-gym|mygym-multiple|mygym-multiple
08-my-gym|machine-selection|machine-selection
08-my-gym|machine-selection-none-selected|machine-selection-none-selected
08-my-gym|custom-machine-add|custom-machine-add
08-my-gym|custom-machine-edit|custom-machine-edit
09-library|exercise-library|exercise-library
09-library|search-results|exercise-library-search-results
09-library|search-no-results|exercise-library-no-results
10-form-guide|form-guide|form-guide
10-form-guide|form-guide-instructions-expanded|form-guide-instructions-expanded
"

# Selected DARK variants (dark appearance, primary device, suffix -dark).
# Representative screens whose Glass/surface treatment differs by scheme.
# Runner is excluded (already forced dark in the light run).
DARK_VARIANTS="
03-home|home|home
05-planner|weekly-candidate|preview-weekly
08-my-gym|mygym-multiple|mygym-multiple
08-my-gym|custom-machine-edit|custom-machine-edit
09-library|exercise-library|exercise-library
"

# Selected NARROW variants (light appearance, narrow device, suffix -narrow).
# Representative screens whose layout is most width-sensitive.
NARROW_VARIANTS="
01-onboarding|onboarding|onboarding
03-home|home|home
05-planner|weekly-candidate|preview-weekly
06-runner|runner-active|runner-active
08-my-gym|machine-selection|machine-selection
"

capture_one() {
  local dev="$1" outdir="$2" stem="$3" route="$4" suffix="$5"
  local path="$outdir/${stem}${suffix}.png"
  if [ -e "$path" ] && [ "$FORCE" -ne 1 ]; then
    fail "$path exists (use --force to overwrite)"
  fi
  xcrun simctl terminate "$dev" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$dev" "$BUNDLE_ID" "$ROUTE_ARG" "$route" >/dev/null 2>&1 \
    || fail "launch failed for $route"
  local wait="$SETTLE"
  case "$route" in *form-guide*) wait=$((SETTLE + FORMGUIDE_DELAY));; esac
  sleep "$wait"
  xcrun simctl io "$dev" screenshot "$path" >/dev/null 2>&1 || fail "screenshot failed for $route"
  printf '  %s\n' "${path#"$OUTPUT"/}"
}

# capture_list <device> <list> <appearance> <suffix>
capture_list() {
  local dev="$1" list="$2" appearance="$3" suffix="$4"
  apply_appearance "$dev" "$appearance"
  echo "$list" | while IFS='|' read -r grp stem route; do
    [ -z "$grp" ] && continue
    [ -n "$GROUP" ] && [ "$grp" != "$GROUP" ] && continue
    local outdir="$OUTPUT/$grp"
    mkdir -p "$outdir"
    capture_one "$dev" "$outdir" "$stem" "$route" "$suffix"
  done
}

info "Capturing…"
case "$VARIANT" in
  light)  capture_list "$DEVICE" "$ROUTES" light "" ;;
  dark)   capture_list "$DEVICE" "$DARK_VARIANTS" dark "-dark" ;;
  narrow) capture_list "$NARROW_DEVICE" "$NARROW_VARIANTS" light "-narrow" ;;
  all)
    info "· canonical (light, primary)"
    capture_list "$DEVICE" "$ROUTES" light ""
    info "· dark variants (primary)"
    capture_list "$DEVICE" "$DARK_VARIANTS" dark "-dark"
    info "· narrow variants (narrow device)"
    capture_list "$NARROW_DEVICE" "$NARROW_VARIANTS" light "-narrow"
    ;;
  *) fail "unknown --variant: $VARIANT" ;;
esac

info "Done. Output: $OUTPUT"
echo "Review every image manually (see Docs/ui-inventory.md). Generated images are not committed."
