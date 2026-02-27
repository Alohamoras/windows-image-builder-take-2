#!/usr/bin/env bash
# run-regression.sh — Build, validate, and Oxide-test all configured Windows
#                     Server versions, then emit a pass/fail summary table.
#
# Usage:
#   ./regression/run-regression.sh [options]
#
# Options:
#   --versions "2022 2025"   Override VERSIONS from regression.conf
#   --skip-build             Skip imgbuild (assume images already exist)
#   --skip-oxide             Skip upload-and-test (build + validate only)
#   --no-cleanup             Skip cleanup-run.sh after each version

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
SKIP_BUILD=false
SKIP_OXIDE=false
NO_CLEANUP=false
VERSIONS_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --versions)    VERSIONS_OVERRIDE="$2"; shift 2 ;;
        --skip-build)  SKIP_BUILD=true; shift ;;
        --skip-oxide)  SKIP_OXIDE=true; shift ;;
        --no-cleanup)  NO_CLEANUP=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Source regression.conf
# ---------------------------------------------------------------------------
CONF="$SCRIPT_DIR/regression.conf"
if [[ ! -f "$CONF" ]]; then
    echo "ERROR: regression.conf not found at $CONF" >&2
    echo "       Copy regression.conf.sample to regression.conf and edit it." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

# Command-line --versions overrides the config value
if [[ -n "$VERSIONS_OVERRIDE" ]]; then
    VERSIONS="$VERSIONS_OVERRIDE"
fi

: "${VERSIONS:?VERSIONS must be set in regression.conf}"
: "${ISO_DIR:?ISO_DIR must be set in regression.conf}"
: "${OUTPUT_DIR:?OUTPUT_DIR must be set in regression.conf}"
: "${VIRTIO_ISO:?VIRTIO_ISO must be set in regression.conf}"
: "${OVMF_PATH:?OVMF_PATH must be set in regression.conf}"
: "${WORK_DIR:?WORK_DIR must be set in regression.conf}"
: "${UNATTEND_DIR:?UNATTEND_DIR must be set in regression.conf}"

# ---------------------------------------------------------------------------
# Helper: colored status word
# ---------------------------------------------------------------------------
status_word() {
    local rc="$1" skipped="${2:-false}"
    if $skipped; then
        echo "SKIP"
    elif [[ "$rc" -eq 0 ]]; then
        echo "PASS"
    else
        echo "FAIL"
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Ensure ISOs are present
# ---------------------------------------------------------------------------
echo "=================================================================="
echo "  wimsy regression suite — versions: $VERSIONS"
echo "=================================================================="
echo ""
echo "==> Checking / downloading ISOs ..."
if ! bash "$SCRIPT_DIR/download-isos.sh"; then
    echo "ERROR: ISO download step failed." >&2
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2: System check (once)
# ---------------------------------------------------------------------------
echo "==> Running system check ..."
if ! bash "$REPO_DIR/imgbuild.sh" check-system; then
    echo "ERROR: check-system failed — cannot proceed." >&2
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 3: Build wimsy binary (once, if not already present)
# ---------------------------------------------------------------------------
WIMSY_BIN="$REPO_DIR/target/release/wimsy"
if [[ ! -x "$WIMSY_BIN" ]]; then
    echo "==> Building wimsy binary ..."
    if ! bash "$REPO_DIR/imgbuild.sh" build; then
        echo "ERROR: wimsy binary build failed." >&2
        exit 1
    fi
    echo ""
else
    echo "==> wimsy binary already present — skipping build."
    echo ""
fi

# ---------------------------------------------------------------------------
# Results accumulator
# ---------------------------------------------------------------------------
# Each entry: "VERSION|BUILD|VALIDATE|OXIDE_TEST"
declare -a RESULTS=()
overall_pass=true

# ---------------------------------------------------------------------------
# Step 4: Per-version loop
# ---------------------------------------------------------------------------
for VER in $VERSIONS; do
    echo "=================================================================="
    echo "  VERSION: Windows Server $VER"
    echo "=================================================================="
    echo ""

    OUTPUT_IMAGE="$OUTPUT_DIR/windows-server-${VER}.raw"
    WINDOWS_ISO="$ISO_DIR/windows-server-${VER}-eval.iso"

    # Per-version unattend override
    UNATTEND_VAR="UNATTEND_DIR_${VER}"
    VER_UNATTEND="${!UNATTEND_VAR:-}"
    EFFECTIVE_UNATTEND="${VER_UNATTEND:-$UNATTEND_DIR}"

    # ------------------------------------------------------------------
    # 4a. Write imgbuild.env for this version
    # ------------------------------------------------------------------
    IMGBUILD_ENV="$REPO_DIR/imgbuild.env"
    cat > "$IMGBUILD_ENV" <<EOF
# Auto-generated by run-regression.sh for Windows Server $VER
WORK_DIR=$WORK_DIR
OUTPUT_IMAGE=$OUTPUT_IMAGE
WINDOWS_ISO=$WINDOWS_ISO
VIRTIO_ISO=$VIRTIO_ISO
UNATTEND_DIR=$EFFECTIVE_UNATTEND
OVMF_PATH=$OVMF_PATH
EOF
    echo "[INFO] imgbuild.env written for WS$VER:"
    sed 's/^/         /' "$IMGBUILD_ENV"
    echo ""

    # ------------------------------------------------------------------
    # 4b. Build
    # ------------------------------------------------------------------
    BUILD_RC=0
    BUILD_SKIP=false

    if $SKIP_BUILD; then
        BUILD_SKIP=true
        echo "[SKIP] build (--skip-build)"
    else
        echo "==> [$VER] Building image ..."
        if bash "$REPO_DIR/imgbuild.sh" build-image; then
            BUILD_RC=0
            echo "[OK] build completed"
        else
            BUILD_RC=$?
            echo "[FAIL] build exited with rc=$BUILD_RC"
        fi
    fi
    echo ""

    # ------------------------------------------------------------------
    # 4c. Validate
    # ------------------------------------------------------------------
    VALIDATE_RC=0
    VALIDATE_SKIP=false

    if $BUILD_SKIP && [[ ! -f "$OUTPUT_IMAGE" ]]; then
        echo "[WARN] $OUTPUT_IMAGE not found — skipping validate"
        VALIDATE_SKIP=true
        VALIDATE_RC=1
    elif [[ "$BUILD_RC" -ne 0 ]]; then
        echo "[SKIP] validate — build failed"
        VALIDATE_SKIP=true
        VALIDATE_RC=1
    else
        echo "==> [$VER] Validating image ..."
        if bash "$REPO_DIR/validate-image.sh" "$OUTPUT_IMAGE"; then
            VALIDATE_RC=0
            echo "[OK] validate completed"
        else
            VALIDATE_RC=$?
            echo "[FAIL] validate exited with rc=$VALIDATE_RC"
        fi
    fi
    echo ""

    # ------------------------------------------------------------------
    # 4d. Oxide test
    # ------------------------------------------------------------------
    TEST_RC=0
    TEST_SKIP=false

    if $SKIP_OXIDE; then
        TEST_SKIP=true
        echo "[SKIP] oxide test (--skip-oxide)"
    elif [[ "$VALIDATE_RC" -ne 0 ]]; then
        TEST_SKIP=true
        echo "[SKIP] oxide test — validate failed/skipped"
    else
        echo "==> [$VER] Running Oxide upload-and-test ..."
        if bash "$REPO_DIR/upload-and-test.sh"; then
            TEST_RC=0
            echo "[OK] oxide test completed"
        else
            TEST_RC=$?
            echo "[FAIL] oxide test exited with rc=$TEST_RC"
        fi
    fi
    echo ""

    # ------------------------------------------------------------------
    # 4e. Cleanup
    # ------------------------------------------------------------------
    if $NO_CLEANUP; then
        echo "[SKIP] cleanup (--no-cleanup)"
    else
        echo "==> [$VER] Cleaning up Oxide resources ..."
        if bash "$REPO_DIR/cleanup-run.sh" --yes; then
            echo "[OK] cleanup done"
        else
            echo "[WARN] cleanup exited non-zero (resources may remain)"
        fi
    fi
    echo ""

    # ------------------------------------------------------------------
    # 4f. Record result
    # ------------------------------------------------------------------
    BUILD_STATUS="$(status_word "$BUILD_RC" "$BUILD_SKIP")"
    VALIDATE_STATUS="$(status_word "$VALIDATE_RC" "$VALIDATE_SKIP")"
    TEST_STATUS="$(status_word "$TEST_RC" "$TEST_SKIP")"

    RESULTS+=("$VER|$BUILD_STATUS|$VALIDATE_STATUS|$TEST_STATUS")

    if [[ "$BUILD_STATUS" == "FAIL" || "$VALIDATE_STATUS" == "FAIL" || "$TEST_STATUS" == "FAIL" ]]; then
        overall_pass=false
    fi
done

# ---------------------------------------------------------------------------
# Step 5: Summary table
# ---------------------------------------------------------------------------
echo "=================================================================="
echo "  REGRESSION SUMMARY"
echo "=================================================================="
printf "  %-10s  %-8s  %-10s  %-12s\n" "VERSION" "BUILD" "VALIDATE" "OXIDE_TEST"
echo "  --------------------------------------------------"
for row in "${RESULTS[@]}"; do
    IFS='|' read -r v b val t <<< "$row"
    printf "  %-10s  %-8s  %-10s  %-12s\n" "$v" "$b" "$val" "$t"
done
echo "=================================================================="
echo ""

if $overall_pass; then
    echo "Result: ALL PASS"
    exit 0
else
    echo "Result: FAILURES DETECTED"
    exit 1
fi
