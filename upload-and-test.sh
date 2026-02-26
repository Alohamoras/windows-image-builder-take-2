#!/usr/bin/env bash
# upload-and-test.sh — Upload, launch, and verify Windows image on Oxide rack
#
# Sources imgbuild.env and oxide.env, uploads the built image as a disk +
# snapshot + image, launches a test instance, and verifies boot via serial
# console output.
#
# Output format: [PASS]/[FAIL]/[WARN]/[INFO]
# Exit 0 if no [FAIL]s, exit 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
warn=0

# Optional flags
_skip_upload=false
_override_image=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-upload)   _skip_upload=true; shift ;;
        --image)         _override_image="$2"; _skip_upload=true; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

pass()  { echo "[PASS] $*"; (( pass++ ));  true; }
fail()  { echo "[FAIL] $*"; (( fail++ ));  true; }
warn()  { echo "[WARN] $*"; (( warn++ ));  true; }
info()  { echo "[INFO] $*"; }

# oxide CLI wrapper — prepends --profile if OXIDE_PROFILE is set
oxide_cmd() {
    if [[ -n "${OXIDE_PROFILE:-}" ]]; then
        oxide --profile "$OXIDE_PROFILE" "$@"
    else
        oxide "$@"
    fi
}

# ---------------------------------------------------------------------------
# 1. Config & pre-flight
# ---------------------------------------------------------------------------
echo ""
echo "==> 1. Config & pre-flight"

# Source imgbuild.env
IMGBUILD_ENV="$SCRIPT_DIR/imgbuild.env"
if [[ ! -f "$IMGBUILD_ENV" ]]; then
    fail "imgbuild.env not found at $IMGBUILD_ENV"
    echo "upload-and-test: ${pass} passed, ${fail} failed, ${warn} warnings"
    exit 1
fi
# shellcheck disable=SC1090
source "$IMGBUILD_ENV"
info "Sourced imgbuild.env"

# Source oxide.env
OXIDE_ENV="$SCRIPT_DIR/oxide.env"
if [[ ! -f "$OXIDE_ENV" ]]; then
    fail "oxide.env not found at $OXIDE_ENV — copy oxide.env.sample and fill it in"
    echo "upload-and-test: ${pass} passed, ${fail} failed, ${warn} warnings"
    exit 1
fi
# shellcheck disable=SC1090
source "$OXIDE_ENV"
info "Sourced oxide.env"

# Validate required config vars before doing anything else
_config_ok=true
if [[ -z "${OXIDE_PROJECT:-}" ]]; then
    fail "OXIDE_PROJECT is not set in oxide.env"
    _config_ok=false
fi
if [[ -z "${OUTPUT_IMAGE:-}" ]]; then
    fail "OUTPUT_IMAGE is not set in imgbuild.env"
    _config_ok=false
fi
if [[ -z "${WINDOWS_ISO:-}" ]]; then
    fail "WINDOWS_ISO is not set in imgbuild.env"
    _config_ok=false
fi
if [[ "$_config_ok" == false ]]; then
    echo "upload-and-test: ${pass} passed, ${fail} failed, ${warn} warnings"
    exit 1
fi
pass "Config files sourced (project: $OXIDE_PROJECT)"

# Check oxide CLI is on PATH
if ! command -v oxide &>/dev/null; then
    fail "oxide CLI not found — install it or add ~/.local/bin to PATH"
    echo "upload-and-test: ${pass} passed, ${fail} failed, ${warn} warnings"
    exit 1
fi
pass "oxide CLI found: $(command -v oxide)"

# Check oxide authentication by probing the target project
if ! oxide_cmd disk list --project "$OXIDE_PROJECT" &>/dev/null; then
    fail "oxide CLI cannot reach project '$OXIDE_PROJECT' — run: oxide auth login"
    echo "upload-and-test: ${pass} passed, ${fail} failed, ${warn} warnings"
    exit 1
fi
pass "oxide CLI authenticated to project '$OXIDE_PROJECT'"

# Verify output image exists and is non-empty (skip when reusing an existing Oxide image)
if [[ "$_skip_upload" == false ]]; then
    if [[ ! -s "$OUTPUT_IMAGE" ]]; then
        fail "Output image not found or empty: $OUTPUT_IMAGE — run phase1 first"
        echo "upload-and-test: ${pass} passed, ${fail} failed, ${warn} warnings"
        exit 1
    fi
    pass "Output image found: $OUTPUT_IMAGE ($(du -h "$OUTPUT_IMAGE" | cut -f1))"
fi

# ---------------------------------------------------------------------------
# Compute auto-generated names
# ---------------------------------------------------------------------------

ISO_BASENAME="$(basename "${WINDOWS_ISO}")"
VERSION=""
for _year in 2025 2022 2019 2016; do
    if [[ "$ISO_BASENAME" == *"$_year"* ]]; then
        VERSION="$_year"
        break
    fi
done
if [[ -z "$VERSION" ]]; then
    VERSION="unknown"
    warn "Could not extract year from ISO name '$ISO_BASENAME' — using 'unknown'"
fi

DATESTAMP="$(date +%Y%m%d)"
DISK_NAME="win-server-${VERSION}-${DATESTAMP}"
SNAP_NAME="win-server-${VERSION}-${DATESTAMP}-snap"
IMAGE_NAME="win-server-${VERSION}-${DATESTAMP}"
INSTANCE_NAME="win-server-${VERSION}-${DATESTAMP}-test"
SERIAL_LOG="./win-server-${VERSION}-${DATESTAMP}-serial.log"

if [[ -n "$_override_image" ]]; then
    IMAGE_NAME="$_override_image"
    info "Using existing image: $IMAGE_NAME"
fi

info "Version:       $VERSION"
info "Datestamp:     $DATESTAMP"
info "Disk name:     $DISK_NAME"
info "Snapshot name: $SNAP_NAME"
info "Image name:    $IMAGE_NAME"
info "Instance name: $INSTANCE_NAME"
info "Serial log:    $SERIAL_LOG"

# ---------------------------------------------------------------------------
# 2. Upload image as disk + snapshot + image
# ---------------------------------------------------------------------------
echo ""
echo "==> 2. Upload image (disk + snapshot + Oxide image)"

if [[ "$_skip_upload" == true ]]; then
    info "Skipping upload — using existing image '$IMAGE_NAME'"
else
    info "Uploading $OUTPUT_IMAGE — this may take several minutes..."
    if oxide_cmd disk import \
        --project         "$OXIDE_PROJECT" \
        --path            "$OUTPUT_IMAGE" \
        --disk            "$DISK_NAME" \
        --disk-block-size 512 \
        --description     "Windows Server $VERSION built $DATESTAMP" \
        --snapshot        "$SNAP_NAME" \
        --image           "$IMAGE_NAME" \
        --image-description "Windows Server $VERSION ($DATESTAMP)" \
        --image-os        windows \
        --image-version   "$VERSION"
    then
        pass "Image uploaded: disk=$DISK_NAME  snap=$SNAP_NAME  image=$IMAGE_NAME"
    else
        fail "oxide disk import failed (see output above)"
        echo "upload-and-test: ${pass} passed, ${fail} failed, ${warn} warnings"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 3. Launch test instance
# ---------------------------------------------------------------------------
echo ""
echo "==> 3. Launch test instance"

_launch_stderr="$(mktemp)"
if oxide_cmd instance from-image \
    --project     "$OXIDE_PROJECT" \
    --name        "$INSTANCE_NAME" \
    --hostname    "${OXIDE_INSTANCE_HOSTNAME:-$INSTANCE_NAME}" \
    --image       "$IMAGE_NAME" \
    --size        "${OXIDE_INSTANCE_DISK_SIZE:-80GiB}" \
    --memory      "${OXIDE_INSTANCE_MEMORY:-8GiB}" \
    --ncpus       "${OXIDE_INSTANCE_NCPUS:-2}" \
    --description "Boot test for $IMAGE_NAME" \
    --start \
    2>"$_launch_stderr"
then
    info "Launched instance $INSTANCE_NAME"
else
    fail "oxide instance from-image failed"
    cat "$_launch_stderr"
    rm -f "$_launch_stderr"
    echo "upload-and-test: ${pass} passed, ${fail} failed, ${warn} warnings"
    exit 1
fi
rm -f "$_launch_stderr"

# ---------------------------------------------------------------------------
# 4. Poll serial console + instance state (concurrent)
# ---------------------------------------------------------------------------
echo ""
echo "==> 4. Poll serial console (max 10 min)"

MAX_ROUNDS=40   # 40 × 15 s = 600 s

# Background subshell: track instance state transitions (informational only)
(
    _prev=""
    for _i in $(seq 1 60); do
        _cur="$(oxide_cmd instance view \
            --instance "$INSTANCE_NAME" \
            --project  "$OXIDE_PROJECT" 2>/dev/null \
            | grep -iE 'run_state' | head -1 \
            | sed 's/.*run_state[^a-z]*//i; s/[^a-z_].*//i')"
        if [[ -n "$_cur" && "$_cur" != "$_prev" ]]; then
            echo "[INFO] Instance state → $_cur"
            _prev="$_cur"
            case "$_cur" in running|failed|stopped) break ;; esac
        fi
        sleep 10
    done
) &
_state_pid=$!

# Main polling loop: fetch serial history, check for success/failure strings
boot_result="timeout"
for round in $(seq 1 $MAX_ROUNDS); do
    oxide_cmd instance serial history \
        --instance "$INSTANCE_NAME" \
        --project  "$OXIDE_PROJECT" \
        --json \
        2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); sys.stdout.buffer.write(bytes(d['data']))" \
        > "$SERIAL_LOG" 2>/dev/null || true

    if grep -q "CMD command is now available" "$SERIAL_LOG" 2>/dev/null; then
        elapsed=$(( round * 15 ))
        pass "SAC prompt found after ~${elapsed}s — instance booted successfully"
        boot_result="pass"
        break
    fi

    if grep -qE "Status: 0xc000|INACCESSIBLE_BOOT_DEVICE" "$SERIAL_LOG" 2>/dev/null; then
        fail "Boot failure detected — see $SERIAL_LOG"
        boot_result="fail"
        break
    fi

    # Check instance state — exit early if it stopped or failed without a good boot
    _inst_state="$(oxide_cmd instance view \
        --instance "$INSTANCE_NAME" \
        --project  "$OXIDE_PROJECT" 2>/dev/null \
        | grep -iE 'run_state' | head -1 \
        | sed 's/.*run_state[^a-z]*//i; s/[^a-z_].*//i')"
    if [[ "$_inst_state" == "failed" || "$_inst_state" == "stopped" ]]; then
        fail "Instance entered state '$_inst_state' without successful boot — see $SERIAL_LOG"
        boot_result="fail"
        break
    fi

    info "Round $round/$MAX_ROUNDS — waiting for boot... (state: ${_inst_state:-unknown})"
    sleep 15
done

# Clean up background state poller
kill "$_state_pid" 2>/dev/null || true
wait "$_state_pid" 2>/dev/null || true

case "$boot_result" in
    timeout) warn "Boot not confirmed within timeout — serial log saved to $SERIAL_LOG" ;;
    pass|fail) info "Serial log saved to $SERIAL_LOG" ;;
esac

# ---------------------------------------------------------------------------
# 5. Capture access info
# ---------------------------------------------------------------------------
echo ""
echo "==> 5. Access info"

# Save instance JSON
_instance_json="${INSTANCE_NAME}.json"
oxide_cmd instance view \
    --instance "$INSTANCE_NAME" \
    --project  "$OXIDE_PROJECT" \
    > "$_instance_json" 2>/dev/null || true
info "Instance details saved to $_instance_json"

# External IPs
_ip_output="$(oxide_cmd instance external-ip list \
    --instance "$INSTANCE_NAME" \
    --project  "$OXIDE_PROJECT" 2>/dev/null || true)"

if [[ -n "$_ip_output" ]]; then
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        info "External IP: $_line"
        _ip_addr="$(printf '%s' "$_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [[ -n "$_ip_addr" ]]; then
            info "To SSH:            ssh oxide@${_ip_addr}"
        fi
    done <<< "$_ip_output"
else
    info "No external IPs found (add one: oxide instance external-ip add -p $OXIDE_PROJECT -i $INSTANCE_NAME)"
fi

info "To connect serial: oxide instance serial console -p $OXIDE_PROJECT -i $INSTANCE_NAME"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "upload-and-test: ${pass} passed, ${fail} failed, ${warn} warnings"

if (( fail > 0 )); then
    exit 1
fi
exit 0
