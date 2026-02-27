#!/usr/bin/env bash
# download-isos.sh — Check for / download Windows Server eval ISOs.
#
# Reads VERSIONS, ISO_DIR, and ISO_URL_<VER> from regression.conf (sourced by
# the caller, or sourced here if run standalone).
#
# Usage (standalone):
#   ./regression/download-isos.sh
#
# Usage (sourced / called from run-regression.sh):
#   The caller must have already sourced regression.conf so that VERSIONS,
#   ISO_DIR, and ISO_URL_* are set.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Source regression.conf if variables are not already in the environment
# ---------------------------------------------------------------------------
if [[ -z "${VERSIONS:-}" ]]; then
    CONF="$SCRIPT_DIR/regression.conf"
    if [[ ! -f "$CONF" ]]; then
        echo "ERROR: regression.conf not found at $CONF" >&2
        echo "       Copy regression.conf.sample to regression.conf and edit it." >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$CONF"
fi

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------
: "${VERSIONS:?VERSIONS must be set}"
: "${ISO_DIR:?ISO_DIR must be set}"

mkdir -p "$ISO_DIR"

# ---------------------------------------------------------------------------
# Per-version check / download
# ---------------------------------------------------------------------------
any_fail=false

for VER in $VERSIONS; do
    ISO_PATH="$ISO_DIR/windows-server-${VER}-eval.iso"
    URL_VAR="ISO_URL_${VER}"
    URL="${!URL_VAR:-}"

    if [[ -f "$ISO_PATH" ]]; then
        echo "[SKIP]     windows-server-${VER}-eval.iso  (already present)"
        continue
    fi

    if [[ -z "$URL" ]]; then
        echo "[ERROR]    windows-server-${VER}-eval.iso  — no URL configured (set ISO_URL_${VER} in regression.conf)" >&2
        any_fail=true
        continue
    fi

    echo "[DOWNLOAD] windows-server-${VER}-eval.iso  <- $URL"
    if curl -L --progress-bar -o "$ISO_PATH" "$URL"; then
        echo "[OK]       windows-server-${VER}-eval.iso  downloaded successfully"
    else
        echo "[ERROR]    windows-server-${VER}-eval.iso  download failed" >&2
        rm -f "$ISO_PATH"   # remove partial file
        any_fail=true
    fi
done

if $any_fail; then
    echo "" >&2
    echo "One or more ISO downloads failed." >&2
    exit 1
fi
