#!/usr/bin/env bash
# cleanup-run.sh — Delete every instance, disk, snapshot, and image in the
#                  Oxide project configured in oxide.env.
#
# Usage:
#   ./cleanup-run.sh [PROJECT]
#       If PROJECT is omitted, uses OXIDE_PROJECT from oxide.env.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Source oxide.env
# ---------------------------------------------------------------------------
OXIDE_ENV="$SCRIPT_DIR/oxide.env"
if [[ ! -f "$OXIDE_ENV" ]]; then
    echo "ERROR: oxide.env not found at $OXIDE_ENV" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$OXIDE_ENV"

if [[ -z "${OXIDE_PROJECT:-}" ]]; then
    echo "ERROR: OXIDE_PROJECT not set in oxide.env" >&2
    exit 1
fi

# Allow overriding the project from the command line
if [[ $# -ge 1 ]]; then
    OXIDE_PROJECT="$1"
fi

# oxide CLI wrapper — prepends --profile if OXIDE_PROFILE is set
oxide_cmd() {
    if [[ -n "${OXIDE_PROFILE:-}" ]]; then
        oxide --profile "$OXIDE_PROFILE" "$@"
    else
        oxide "$@"
    fi
}

# ---------------------------------------------------------------------------
# Helper: parse a JSON array of objects and print the "name" field of each
# ---------------------------------------------------------------------------
extract_names() {
    python3 -c "import sys,json; [print(x['name']) for x in json.load(sys.stdin)]" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: move a disk out of any import state so it can be deleted.
#   importing_from_bulk_writes -> call import stop  -> import_ready
#   import_ready               -> call import finalize (no snapshot) -> detached
# ---------------------------------------------------------------------------
unblock_disk_for_delete() {
    local disk="$1"
    local state
    state="$(oxide_cmd disk view \
        --disk    "$disk" \
        --project "$OXIDE_PROJECT" \
        2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); s=d.get('state',{}); print(s.get('state','') if isinstance(s,dict) else s)" \
        2>/dev/null || echo "")"

    if [[ "$state" == "importing_from_bulk_writes" ]]; then
        echo -n "  Stopping bulk-write import for '$disk' ... "
        if oxide_cmd disk import stop \
            --disk    "$disk" \
            --project "$OXIDE_PROJECT" \
            2>/dev/null; then
            echo "stopped"
        else
            echo "stop failed (will try delete anyway)"
            return
        fi
        state="import_ready"
    fi

    if [[ "$state" == "import_ready" ]]; then
        echo -n "  Finalizing '$disk' (no snapshot) to make it deletable ... "
        if oxide_cmd disk import finalize \
            --disk    "$disk" \
            --project "$OXIDE_PROJECT" \
            2>/dev/null; then
            echo "done"
        else
            echo "finalize failed (will try delete anyway)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Confirm before doing anything destructive
# ---------------------------------------------------------------------------
echo "=================================================="
echo "  PROJECT: $OXIDE_PROJECT"
echo "=================================================="
echo "This will delete ALL instances, disks, snapshots,"
echo "and images in the project above."
echo ""
read -rp "Continue? [y/N] " _CONFIRM
if [[ "$_CONFIRM" != "y" && "$_CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi
echo ""

# ---------------------------------------------------------------------------
# Instances: stop running ones, then delete all
# ---------------------------------------------------------------------------
echo "==> Collecting instances ..."
mapfile -t INSTANCES < <(
    oxide_cmd instance list \
        --project "$OXIDE_PROJECT" \
        2>/dev/null \
    | extract_names
)

if [[ ${#INSTANCES[@]} -eq 0 ]]; then
    echo "  No instances found."
fi

for INST in "${INSTANCES[@]}"; do
    STATE="$(oxide_cmd instance view \
        --instance "$INST" \
        --project  "$OXIDE_PROJECT" \
        2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['run_state'])" 2>/dev/null \
        || echo "not-found")"

    if [[ "$STATE" != "stopped" && "$STATE" != "failed" && "$STATE" != "not-found" ]]; then
        echo "  Stopping instance '$INST' (state: $STATE) ..."
        oxide_cmd instance stop \
            --instance "$INST" \
            --project  "$OXIDE_PROJECT" \
            >/dev/null 2>&1 || true

        echo -n "  Waiting"
        for _ in $(seq 1 24); do
            sleep 5
            STATE="$(oxide_cmd instance view \
                --instance "$INST" \
                --project  "$OXIDE_PROJECT" \
                2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['run_state'])" 2>/dev/null \
                || echo "not-found")"
            echo -n "."
            if [[ "$STATE" == "stopped" || "$STATE" == "failed" || "$STATE" == "not-found" ]]; then
                break
            fi
        done
        echo " $STATE"
        if [[ "$STATE" != "stopped" && "$STATE" != "failed" && "$STATE" != "not-found" ]]; then
            echo "  WARNING: '$INST' did not stop within 2 minutes — attempting delete anyway" >&2
        fi
    else
        echo "  Instance '$INST' is $STATE — no stop needed"
    fi

    echo -n "  Deleting instance '$INST' ... "
    if oxide_cmd instance delete \
        --instance "$INST" \
        --project  "$OXIDE_PROJECT" \
        2>/dev/null; then
        echo "deleted"
    else
        echo "already gone"
    fi
done

# ---------------------------------------------------------------------------
# Disks
# ---------------------------------------------------------------------------
echo ""
echo "==> Collecting disks ..."
mapfile -t DISKS < <(
    oxide_cmd disk list \
        --project "$OXIDE_PROJECT" \
        2>/dev/null \
    | extract_names
)

if [[ ${#DISKS[@]} -eq 0 ]]; then
    echo "  No disks found."
fi

for DISK in "${DISKS[@]}"; do
    unblock_disk_for_delete "$DISK"
    echo -n "  Deleting disk '$DISK' ... "
    if oxide_cmd disk delete \
        --disk    "$DISK" \
        --project "$OXIDE_PROJECT" \
        2>/dev/null; then
        echo "deleted"
    else
        echo "already gone"
    fi
done

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------
echo ""
echo "==> Collecting snapshots ..."
mapfile -t SNAPS < <(
    oxide_cmd snapshot list \
        --project "$OXIDE_PROJECT" \
        2>/dev/null \
    | extract_names
)

if [[ ${#SNAPS[@]} -eq 0 ]]; then
    echo "  No snapshots found."
fi

for SNAP in "${SNAPS[@]}"; do
    echo -n "  Deleting snapshot '$SNAP' ... "
    if oxide_cmd snapshot delete \
        --snapshot "$SNAP" \
        --project  "$OXIDE_PROJECT" \
        2>/dev/null; then
        echo "deleted"
    else
        echo "already gone"
    fi
done

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
echo ""
echo "==> Collecting images ..."
mapfile -t IMAGES < <(
    oxide_cmd image list \
        --project "$OXIDE_PROJECT" \
        2>/dev/null \
    | extract_names
)

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    echo "  No images found."
fi

for IMG in "${IMAGES[@]}"; do
    echo -n "  Deleting image '$IMG' ... "
    if oxide_cmd image delete \
        --image   "$IMG" \
        --project "$OXIDE_PROJECT" \
        2>/dev/null; then
        echo "deleted"
    else
        echo "already gone"
    fi
done

echo ""
echo "Done. All resources removed from project '$OXIDE_PROJECT'."
