#!/usr/bin/env bash
# validate-image.sh — Post-build validation for wimsy Windows images
# Copies the image (sparse), mounts it read-only, and verifies key build outcomes.
# Output format: [PASS]/[FAIL]/[WARN]/[INFO].
# Exit 0 if no [FAIL]s, exit 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
warn=0

pass()  { echo "[PASS] $*"; (( pass++ )); true; }
fail()  { echo "[FAIL] $*"; (( fail++ )); true; }
warn()  { echo "[WARN] $*"; (( warn++ )); true; }
info()  { echo "[INFO] $*"; }

# ---------------------------------------------------------------------------
# 0. Parse arguments / load imgbuild.env
# ---------------------------------------------------------------------------
echo ""
echo "==> 0. Setup"

ENV_FILE="$SCRIPT_DIR/imgbuild.env"

if [[ $# -ge 1 ]]; then
    IMAGE="$1"
else
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        IMAGE="${OUTPUT_IMAGE:-}"
    else
        IMAGE=""
    fi
fi

if [[ -z "${IMAGE:-}" ]]; then
    fail "No image path provided and OUTPUT_IMAGE not set in imgbuild.env"
    echo ""
    echo "Usage: $0 [/path/to/image.raw]"
    exit 1
fi

if [[ ! -f "$IMAGE" ]]; then
    fail "Image not found: $IMAGE"
    exit 1
fi

info "Image: $IMAGE"
image_size=$(stat -c '%s' "$IMAGE")
info "Image file size: $(( image_size / 1024 / 1024 )) MiB"

# ---------------------------------------------------------------------------
# 1. Tool checks
# ---------------------------------------------------------------------------
echo ""
echo "==> 1. Tool checks"

tools_ok=true
for tool in sgdisk losetup stat sudo; do
    if command -v "$tool" &>/dev/null; then
        pass "$tool is available"
    else
        fail "$tool is not available"
        tools_ok=false
    fi
done

# ntfs-3g may live outside PATH on some systems — check common locations too
if command -v ntfs-3g &>/dev/null || \
   [[ -x /usr/bin/ntfs-3g ]] || \
   [[ -x /sbin/mount.ntfs-3g ]]; then
    pass "ntfs-3g is available"
else
    warn "ntfs-3g not found — filesystem checks may fail (apt install ntfs-3g)"
fi

if command -v hivexget &>/dev/null; then
    pass "hivexget is available (EMS/BCD check enabled)"
else
    warn "hivexget not found — EMS check will be skipped (apt install libhivex-bin)"
fi

if ! $tools_ok; then
    echo ""
    echo "validate-image: ${pass} passed, ${fail} failed, ${warn} warnings"
    echo "Aborting: required tools are missing."
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Prepare sparse copy and register cleanup trap
# ---------------------------------------------------------------------------
echo ""
echo "==> 2. Preparing image copy"

COPY="/tmp/wimsy-validate-$$.raw"
MOUNT_DIR="/tmp/wimsy-mnt-$$"
EFI_MOUNT_DIR="/tmp/wimsy-efi-mnt-$$"
LOOP_DEV=""

cleanup() {
    sudo umount "$MOUNT_DIR" 2>/dev/null || true
    sudo umount "$EFI_MOUNT_DIR" 2>/dev/null || true
    if [[ -n "${LOOP_DEV}" ]]; then
        sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    rm -f "$COPY"
    rmdir "$MOUNT_DIR" 2>/dev/null || true
    rmdir "$EFI_MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

actual_usage=$(du -sb "$IMAGE" | cut -f1)
info "Estimated sparse copy size: $(( actual_usage / 1024 / 1024 )) MiB"
info "Copying image (this may take a minute)..."

if ! cp --sparse=always "$IMAGE" "$COPY"; then
    fail "Failed to create sparse copy of image"
    exit 1
fi
pass "Image copied to $COPY"

mkdir -p "$MOUNT_DIR"

# ---------------------------------------------------------------------------
# 3. Attach loop device
# ---------------------------------------------------------------------------
echo ""
echo "==> 3. Attaching loop device"

LOOP_DEV=$(sudo losetup -Pr --find --show "$COPY" 2>/dev/null || true)
if [[ -z "${LOOP_DEV:-}" ]]; then
    fail "losetup failed — could not attach loop device"
    exit 1
fi
pass "Loop device: $LOOP_DEV"

# ---------------------------------------------------------------------------
# 4. Structural checks (GPT and partition layout; no mount required)
# ---------------------------------------------------------------------------
echo ""
echo "==> 4. Structural checks"

# 4a. GPT integrity
if sudo sgdisk -v "$LOOP_DEV" &>/dev/null; then
    pass "GPT is valid (sgdisk -v)"
else
    fail "GPT validation failed — sgdisk -v reported errors"
fi

# Capture full partition table for the remaining checks
sgdisk_output=$(sudo sgdisk -p "$LOOP_DEV" 2>/dev/null)

# Extract partition entry lines (lines beginning with optional whitespace + a digit)
part_lines=$(echo "$sgdisk_output" | grep -E '^\s+[0-9]+\s+[0-9]+' || true)

part_count=0
if [[ -n "$part_lines" ]]; then
    part_count=$(printf '%s\n' "$part_lines" | wc -l)
fi

# 4b. Partition count must be exactly 4
if [[ "$part_count" -eq 4 ]]; then
    pass "Partition count: 4"
else
    fail "Partition count: $part_count (expected 4; trailing recovery partition may not have been deleted)"
fi

# 4c. Partition type order: 2700 (Recovery), EF00 (ESP), 0C01 (MSR), 0700 (OS)
# sgdisk -p format: Number  Start  End  Size  Unit  Code  Name
# Column 6 (awk $6) is the type code.
mapfile -t part_types < <(printf '%s\n' "$part_lines" | awk '{print toupper($6)}')

expected_types=("2700" "EF00" "0C01" "0700")
expected_names=("Recovery" "ESP" "MSR" "OS data")

if [[ ${#part_types[@]} -eq 4 ]]; then
    types_ok=true
    for i in 0 1 2 3; do
        if [[ "${part_types[$i]:-}" != "${expected_types[$i]}" ]]; then
            fail "Partition $((i+1)) type '${part_types[$i]:-?}' (expected ${expected_types[$i]} ${expected_names[$i]})"
            types_ok=false
        fi
    done
    if $types_ok; then
        pass "Partition types in order: 2700 (Recovery), EF00 (ESP), 0C01 (MSR), 0700 (OS)"
    fi

    # Explicit check: last partition must be 0700, not a trailing 2700
    if [[ "${part_types[3]:-}" == "0700" ]]; then
        pass "Last partition is OS data (0700), not a trailing recovery partition"
    else
        fail "Last partition type is '${part_types[3]:-?}' — expected 0700; trailing recovery partition may not have been removed"
    fi
else
    warn "Cannot verify partition type order (unexpected partition count: ${#part_types[@]})"
fi

# 4d. Image size check — confirm the image was shrunk after install
# After shrink + GPT repair, file size should be ≤ (last_end_sector + 1 + 33) * sector_size
# The +33 accounts for the backup GPT (1 header sector + 32 partition table sectors).
sector_size=$(echo "$sgdisk_output" | awk '/Sector size/ {split($4, a, "/"); print a[1]+0}')
sector_size="${sector_size:-512}"

last_end=$(printf '%s\n' "$part_lines" | awk '{print $3}' | sort -n | tail -1)
last_end="${last_end:-0}"

if [[ "$last_end" -gt 0 && "$sector_size" -gt 0 ]]; then
    expected_max=$(( (last_end + 1 + 33) * sector_size ))
    if [[ "$image_size" -le "$expected_max" ]]; then
        pass "Image size ($(( image_size / 1024 / 1024 )) MiB) ≤ shrink limit ($(( expected_max / 1024 / 1024 )) MiB)"
    else
        fail "Image size ($(( image_size / 1024 / 1024 )) MiB) > shrink limit ($(( expected_max / 1024 / 1024 )) MiB) — image may not have been shrunk"
    fi
else
    warn "Could not determine shrink limit (last_end=${last_end}, sector_size=${sector_size}) — skipping size check"
fi

# ---------------------------------------------------------------------------
# 5. Filesystem checks (mount OS partition read-only)
# ---------------------------------------------------------------------------
echo ""
echo "==> 5. Filesystem checks"

os_part="${LOOP_DEV}p4"

if [[ ! -b "$os_part" ]]; then
    fail "OS partition device $os_part does not exist — cannot proceed with filesystem checks"
    echo ""
    echo "validate-image: ${pass} passed, ${fail} failed, ${warn} warnings"
    if (( fail > 0 )); then exit 1; fi
    exit 0
fi

if ! sudo mount -t ntfs-3g -o ro "$os_part" "$MOUNT_DIR" 2>/dev/null; then
    fail "Could not mount OS partition ($os_part) as NTFS read-only — filesystem may be corrupt or incomplete"
    echo ""
    echo "validate-image: ${pass} passed, ${fail} failed, ${warn} warnings"
    if (( fail > 0 )); then exit 1; fi
    exit 0
fi
pass "OS partition mounted read-only at $MOUNT_DIR"

# 5f. Sysprep succeeded tag (confirms Autounattend.xml + sysprep ran to completion)
sysprep_tag="$MOUNT_DIR/Windows/System32/Sysprep/Sysprep_succeeded.tag"
if [[ -f "$sysprep_tag" ]]; then
    pass "Sysprep completed (sysprep_succeeded.tag present)"
else
    fail "sysprep_succeeded.tag not found — sysprep may not have completed"
fi

# 5g. Registry hives present (confirms Windows installation is intact)
for hive in SYSTEM SOFTWARE; do
    hive_path="$MOUNT_DIR/Windows/System32/config/$hive"
    if [[ -f "$hive_path" ]]; then
        pass "Registry hive present: Windows/System32/config/$hive"
    else
        fail "Registry hive missing: Windows/System32/config/$hive"
    fi
done

# 5h. Driver store non-empty (confirms offlineServicing driver injection ran)
driver_repo="$MOUNT_DIR/Windows/System32/DriverStore/FileRepository"
if [[ -d "$driver_repo" ]]; then
    driver_count=$(find "$driver_repo" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    if [[ "$driver_count" -gt 0 ]]; then
        pass "DriverStore/FileRepository: $driver_count driver package(s) staged"
    else
        fail "DriverStore/FileRepository exists but is empty — driver injection may have failed"
    fi
else
    fail "DriverStore/FileRepository not found — Windows installation may be incomplete"
fi

# 5i. No leftover unattend.xml in Windows/Panther (sysprep should have consumed it)
leftover="$MOUNT_DIR/Windows/Panther/unattend.xml"
if [[ ! -f "$leftover" ]]; then
    pass "No leftover Windows/Panther/unattend.xml (expected after successful sysprep)"
else
    warn "Windows/Panther/unattend.xml is still present — sysprep may not have fully processed it"
fi

# 5j. NetKVM (virtio-net) driver staged
netkvm=$(find "$MOUNT_DIR/Windows/System32/DriverStore/FileRepository" \
    -iname "netkvm.inf" -print -quit 2>/dev/null)
if [[ -n "$netkvm" ]]; then
    pass "NetKVM (virtio-net) driver staged: $(basename "$(dirname "$netkvm")")"
else
    fail "NetKVM (virtio-net) driver not found in DriverStore — networking will fail on Oxide"
fi

# 5k. viostor (virtio-blk) driver staged
viostor=$(find "$MOUNT_DIR/Windows/System32/DriverStore/FileRepository" \
    -iname "viostor.inf" -print -quit 2>/dev/null)
if [[ -n "$viostor" ]]; then
    pass "viostor (virtio-blk) driver staged: $(basename "$(dirname "$viostor")")"
else
    fail "viostor (virtio-blk) driver not found in DriverStore — cloud-init metadata drive will be inaccessible"
fi

# 5l. cloudbase-init installed
cbi="$MOUNT_DIR/Program Files/Cloudbase Solutions/Cloudbase-Init/Python/Scripts/cloudbase-init.exe"
if [[ -f "$cbi" ]]; then
    pass "cloudbase-init is installed"
else
    fail "cloudbase-init not found — Oxide provisioning (hostname, SSH keys, disk extension) will not work"
fi

# 5m. SSH server present (WS2025 inbox or older installed location)
sshd_inbox="$MOUNT_DIR/Windows/System32/OpenSSH/sshd.exe"
sshd_installed="$MOUNT_DIR/Program Files/OpenSSH/sshd.exe"
if [[ -f "$sshd_inbox" || -f "$sshd_installed" ]]; then
    pass "SSH server (sshd.exe) is present"
else
    fail "sshd.exe not found — no remote access possible on Oxide (no graphical console)"
fi

# ---------------------------------------------------------------------------
# 6. EFI partition checks (BCD / serial console)
# ---------------------------------------------------------------------------
echo ""
echo "==> 6. EFI partition checks (BCD / serial console)"

efi_part="${LOOP_DEV}p2"
mkdir -p "$EFI_MOUNT_DIR"
if ! sudo mount -t vfat -o ro "$efi_part" "$EFI_MOUNT_DIR" 2>/dev/null; then
    fail "Could not mount EFI partition ($efi_part)"
else
    pass "EFI partition mounted read-only"
    bcd="$EFI_MOUNT_DIR/EFI/Microsoft/Boot/BCD"

    # 6a. BCD file present
    if [[ -f "$bcd" ]]; then
        pass "BCD store present at EFI/Microsoft/Boot/BCD"
    else
        fail "BCD store not found — boot configuration is missing"
    fi

    # 6b. EMS enabled in BCD
    if [[ -f "$bcd" ]] && command -v hivexget &>/dev/null; then
        ems_found=false
        while IFS= read -r obj_guid; do
            raw=$(hivexget "$bcd" "\\Objects\\${obj_guid}\\Elements\\26000020\\Element" 2>/dev/null || true)
            # DWORD true = little-endian 0x01000000
            if [[ "$raw" == *"0x01"* ]]; then
                ems_found=true
                break
            fi
        done < <(hivexget "$bcd" '\Objects' 2>/dev/null | grep -oE '\{[^}]+\}')

        if $ems_found; then
            pass "EMS (serial console) is enabled in BCD"
        else
            fail "EMS not enabled in BCD — serial console will not work on Oxide (bcdedit /ems on was not run)"
        fi
    elif [[ -f "$bcd" ]]; then
        warn "Skipping EMS check — hivexget not available (apt install libhivex-bin)"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "validate-image: ${pass} passed, ${fail} failed, ${warn} warnings"

if (( fail > 0 )); then
    exit 1
fi
exit 0
