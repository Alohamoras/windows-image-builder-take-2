#!/usr/bin/env bash
# phase0.sh — Pre-flight checks for wimsy image builds
# Runs four sequential checks and reports [PASS]/[FAIL]/[WARN]/[INFO].
# Exit 0 if no [FAIL]s, exit 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
warn=0

pass()  { echo "[PASS] $*"; (( pass++ ));  true; }
fail()  { echo "[FAIL] $*"; (( fail++ ));  true; }
warn()  { echo "[WARN] $*"; (( warn++ ));  true; }
info()  { echo "[INFO] $*"; }

# ---------------------------------------------------------------------------
# 1. Git repo status
# ---------------------------------------------------------------------------
echo ""
echo "==> 1. Git repo status"

if ! git -C "$SCRIPT_DIR" fetch origin --quiet 2>/dev/null; then
    warn "Could not reach origin — skipping remote comparison"
else
    current_branch="$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null)"
    if [[ -z "$current_branch" ]]; then
        warn "Detached HEAD — cannot compare with origin"
    else
        local_ref="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
        remote_ref="$(git -C "$SCRIPT_DIR" rev-parse "origin/${current_branch}" 2>/dev/null || true)"
        base_ref="$(git -C "$SCRIPT_DIR" merge-base HEAD "origin/${current_branch}" 2>/dev/null || true)"

        if [[ -z "$remote_ref" ]]; then
            warn "Branch '${current_branch}' has no upstream on origin"
        elif [[ "$local_ref" == "$remote_ref" ]]; then
            pass "Repo is up to date with origin/${current_branch}"
        elif [[ "$local_ref" == "$base_ref" ]]; then
            behind="$(git -C "$SCRIPT_DIR" rev-list --count HEAD..origin/${current_branch})"
            warn "Repo is ${behind} commit(s) behind origin/${current_branch} — consider pulling"
        elif [[ "$remote_ref" == "$base_ref" ]]; then
            ahead="$(git -C "$SCRIPT_DIR" rev-list --count origin/${current_branch}..HEAD)"
            warn "Repo is ${ahead} commit(s) ahead of origin/${current_branch}"
        else
            warn "Repo has diverged from origin/${current_branch}"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2. Windows ISO check
# ---------------------------------------------------------------------------
echo ""
echo "==> 2. Windows ISO check"

ENV_FILE="$SCRIPT_DIR/imgbuild.env"
if [[ ! -f "$ENV_FILE" ]]; then
    fail "imgbuild.env not found at $ENV_FILE — cannot check ISO paths"
else
    # shellcheck disable=SC1090
    source "$ENV_FILE"

    if [[ -n "${WINDOWS_ISO:-}" && -s "$WINDOWS_ISO" ]]; then
        pass "Windows ISO found: $WINDOWS_ISO"
    else
        # Infer version from filename for a helpful download hint
        iso_name="$(basename "${WINDOWS_ISO:-}")"
        case "$iso_name" in
            *2025*)
                url="https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us"
                hint="Server 2025 evaluation ISO (~5.7 GB)"
                ;;
            *2022*)
                url="https://go.microsoft.com/fwlink/p/?linkid=2195686&clcid=0x409&culture=en-us&country=us"
                hint="Server 2022 evaluation ISO"
                ;;
            *)
                url=""
                hint=""
                ;;
        esac

        fail "Windows ISO not found at ${WINDOWS_ISO:-<WINDOWS_ISO not set>}"
        if [[ -n "$url" ]]; then
            echo "       Download ${hint} from:"
            echo "       $url"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 3. VirtIO ISO check / download
# ---------------------------------------------------------------------------
echo ""
echo "==> 3. VirtIO ISO check"

VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

if [[ -n "${VIRTIO_ISO:-}" && -s "$VIRTIO_ISO" ]]; then
    pass "VirtIO ISO found: $VIRTIO_ISO"
elif [[ -z "${VIRTIO_ISO:-}" ]]; then
    fail "VIRTIO_ISO is not set in imgbuild.env"
else
    info "VirtIO ISO not found — downloading latest from Fedora People..."
    mkdir -p "$(dirname "$VIRTIO_ISO")"
    if curl -L --fail --progress-bar -o "$VIRTIO_ISO" "$VIRTIO_URL"; then
        pass "VirtIO ISO downloaded to $VIRTIO_ISO"
    else
        rm -f "$VIRTIO_ISO"
        fail "VirtIO ISO download failed (tried $VIRTIO_URL)"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Dependency check + auto-fix
# ---------------------------------------------------------------------------
echo ""
echo "==> 4. Dependency check"

check_tool() {
    local name="$1"
    command -v "$name" &>/dev/null
}

tools_ok=true

# Build list of missing tools (excluding KVM device and group)
missing_tools=()
for tool in qemu-system-x86_64 qemu-img genisoimage sgdisk curl cargo rustc; do
    if ! check_tool "$tool"; then
        missing_tools+=("$tool")
    fi
done

if (( ${#missing_tools[@]} > 0 )); then
    info "Missing tools: ${missing_tools[*]}"
    install_script="$SCRIPT_DIR/install_prerequisites.sh"
    if [[ -x "$install_script" ]]; then
        info "Running install_prerequisites.sh to install missing dependencies..."
        if "$install_script"; then
            info "install_prerequisites.sh completed — re-checking tools"
            # Re-source PATH in case cargo/rustc were freshly installed
            if [[ -f "$HOME/.cargo/env" ]]; then
                # shellcheck disable=SC1091
                source "$HOME/.cargo/env"
            fi
        else
            info "install_prerequisites.sh exited non-zero — will report remaining failures"
        fi
    else
        info "install_prerequisites.sh not found or not executable — skipping auto-install"
    fi
fi

# Final per-tool verdict (after possible install)
for tool in qemu-system-x86_64 qemu-img genisoimage sgdisk curl cargo rustc; do
    if check_tool "$tool"; then
        pass "$tool is available"
    else
        fail "$tool is not available (install_prerequisites.sh did not resolve it)"
        tools_ok=false
    fi
done

# KVM device — warn only, can't auto-fix
if [[ -e /dev/kvm ]]; then
    pass "/dev/kvm exists"
else
    warn "/dev/kvm not found — is KVM enabled in BIOS/kernel? (cannot auto-fix)"
fi

# KVM group — warn only (need re-login after fix)
if groups | grep -qw kvm; then
    pass "Current user is in the 'kvm' group"
else
    # Attempt the fix, but only warn (needs re-login to take effect)
    info "Adding $USER to 'kvm' group..."
    sudo usermod -aG kvm "$USER" 2>/dev/null || true
    warn "User added to 'kvm' group — you must re-login for this to take effect"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "phase0: ${pass} passed, ${fail} failed, ${warn} warnings"

if (( fail > 0 )); then
    exit 1
fi
exit 0
