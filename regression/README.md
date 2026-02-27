# wimsy Regression Test Suite

Automates building, validating, and Oxide-testing all four Windows Server
versions (2016, 2019, 2022, 2025) in a single unattended run.

## Files

| File | Purpose |
|------|---------|
| `run-regression.sh` | Main orchestrator — runs the full pipeline per version |
| `download-isos.sh` | Checks for / downloads eval ISOs from Microsoft |
| `regression.conf.sample` | Config template — copy to `regression.conf` and edit |
| `regression.conf` | Your local config (git-ignored) |

## Quick Start

```bash
# 1. Create your config
cp regression/regression.conf.sample regression/regression.conf
$EDITOR regression/regression.conf   # adjust paths and verify ISO URLs

# 2. Run a single version (recommended first test)
./regression/run-regression.sh --versions 2025

# 3. Run all versions
./regression/run-regression.sh
```

## Prerequisites

Same as a normal wimsy build:
- KVM-capable host with QEMU installed
- `oxide` CLI configured with a valid profile and project (`oxide.env`)
- Rust toolchain (for building the wimsy binary)
- `virtio-win.iso` and OVMF firmware at the paths set in `regression.conf`

The suite will download any missing Windows Server eval ISOs automatically on
first run (each is ~5 GB; 2025 requires a Microsoft account redirect).

## Configuration

Copy `regression.conf.sample` to `regression.conf` and set:

| Variable | Description |
|----------|-------------|
| `ISO_DIR` | Where ISOs are stored / downloaded |
| `OUTPUT_DIR` | Where built `.raw` images land |
| `VIRTIO_ISO` | Path to `virtio-win.iso` |
| `UNATTEND_DIR` | Default unattend XML directory |
| `OVMF_PATH` | UEFI firmware file |
| `WORK_DIR` | Temp directory for QEMU scratch files |
| `VERSIONS` | Space-separated list: `"2016 2019 2022 2025"` |
| `UNATTEND_DIR_<VER>` | Per-version unattend override (optional) |
| `ISO_URL_<VER>` | Microsoft Eval Center download URL per version |

`regression.conf` is sourced as a bash script, so standard shell syntax applies.

## Flags

```
./regression/run-regression.sh [options]

  --versions "2022 2025"   Override VERSIONS from regression.conf
  --skip-build             Skip image build (assume .raw files already exist)
  --skip-oxide             Skip Oxide upload-and-test (build + validate only)
  --no-cleanup             Leave Oxide resources up after each version
```

## Pipeline (per version)

```
ISO check/download
      |
check-system  (once)
      |
build wimsy binary  (once, skipped if already compiled)
      |
  for each VERSION:
      |
      +-- write imgbuild.env
      +-- imgbuild.sh build-image      → BUILD
      +-- validate-image.sh            → VALIDATE  (skipped if BUILD failed)
      +-- upload-and-test.sh           → OXIDE_TEST (skipped if VALIDATE failed)
      +-- cleanup-run.sh --yes         (always runs unless --no-cleanup)
```

Each step is skipped (marked `SKIP` in the summary) if a prior step failed,
so a build failure won't leave orphaned Oxide resources.

## Summary Table

At the end of a run you'll see something like:

```
==================================================================
  REGRESSION SUMMARY
==================================================================
  VERSION     BUILD     VALIDATE    OXIDE_TEST
  --------------------------------------------------
  2016        PASS      PASS        PASS
  2019        PASS      PASS        PASS
  2022        PASS      PASS        PASS
  2025        PASS      PASS        PASS
==================================================================

Result: ALL PASS
```

Exit code is `0` if all columns are PASS/SKIP with no failures, `1` otherwise.

## Notes

- **imgbuild.env is overwritten** for each version. Do not rely on it being
  stable during a regression run.
- **Unattend compatibility**: The default `./unattend` directory is tested
  against WS2025. Older versions may need different `Autounattend.xml` edition
  selections. Use `UNATTEND_DIR_<VER>` overrides to point at version-specific
  unattend trees.
- **Build time**: Each image build takes 30–60 minutes. A four-version run can
  take several hours. Use `--skip-build` on repeat runs once images are built.
- **ISO URLs**: Microsoft's Eval Center redirects can change. If a downloaded
  ISO turns out to be the wrong version, update `ISO_URL_<VER>` in
  `regression.conf`.
