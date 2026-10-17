# Common Foundry ProductionV4 AMD HIP worker

This directory contains a native HIP replay/search worker for the exact Common
Foundry Mainnet `v1.0.13` ProductionV4 model.  It implements the coordinator's
persistent `READY` / `RUNBATCH` / `DONE` / `EVICT` protocol and preserves the
official activation encoding byte for byte.

## Support model

- Production/pool qualified: AMD Radeon RX 7900 XTX (`gfx1100`)
- Functionally hardware-tested: integrated AMD Radeon Graphics (`gfx1036`),
  exact batch32 but only 0.0887 effective FW/s and no pool claim
- ROCm/HIP 7.14 and rocBLAS
- Mainnet source commit `54b127b296eb2019c623fa8ac4ddff5f78516a7c`
- `MODEL-V2.bank`, 6,442,975,416 bytes, SHA-256
  `5f9b213c3bda51b74e4ebabb26607b67385d613aa8d99af915a48ab063e17d4e`

The default worker is a configurable fat binary containing `gfx906`,
`gfx908`, `gfx90a`, `gfx942`, `gfx1010`–`gfx1012`,
`gfx1030`–`gfx1032`, `gfx1034`–`gfx1036`, `gfx1100`–`gfx1103`,
`gfx1150`, `gfx1151`, `gfx1200` and `gfx1201`. Code-object presence is
not a hardware-validation claim. A device is launch-compatible only when the
binary contains its architecture, the packaged rocBLAS contains the same
architecture, at least 7,767,843,456 bytes are available, 512-thread workgroups are
supported, and the integrated-GPU policy permits it. Every production start
then runs a short exact arithmetic/INT8 self-test; it is not a benchmark.

## Build and test

Required build tools are CMake 3.21 or newer, a C++20-capable ROCm/HIP
toolchain, `amdhip64`, and rocBLAS. The current qualified environment is ROCm
7.14.1 on Linux.

```bash
./build.sh
./test.sh
# Optional packager override:
CMFD_HIP_ARCHITECTURES='gfx1030;gfx1100;gfx1200' ./build.sh
# Optional clean package directory:
cmake --install build --prefix /absolute/output/directory
./package-linux.sh /absolute/output/directory
```

End users do not build this source. The release package contains prebuilt
binaries and `cmfd-hip-runtime`, which reuses a coherent local ROCm 7.14
installation or, after explicit consent, atomically prepares official AMD
user-space components in a private directory. Normal subsequent starts are
offline and do not compile, download or query a remote repository. See
[`LINUX_DEPLOYMENT.md`](LINUX_DEPLOYMENT.md).

The package does not duplicate the official coordinator or model. Installed
diagnostics require `CMFD_MODEL_BANK`; pool launch additionally requires
`CMFD_MINER_BINARY` (or `CMFD_MINER_PACKAGE`), the public payout address and a
currently authenticated pinned pool URL.

The self-test differentially checks exact signed-int8 GEMM, ProductionV4 field
reduction, cubing, coordinate masks and four-limb output encoding. It requires
access to `/dev/kfd` and `/dev/dri`.

The CPU-only test suite also checks the persistent command grammar, normal
`QUIT`, stdin EOF, command/handler errors, marker ordering and termination
signal diagnostics. To exercise the same lifecycle against the real worker
without running a batch or connecting to a pool:

```bash
python3 tests/test_live_worker_lifecycle.py \
  build/bin/cmfd-v4-hip-replay /absolute/path/to/MODEL-V2.bank \
  --selector 'uuid:VALUE_FROM_DISCOVERY'
```

## Native AMD discovery

`build/bin/cmfd-hip-discovery` is an independent, machine-readable HIP device
probe. It reports every HIP GPU with its real name, architecture, total and
currently available memory, integrated/discrete flag, compute limits,
UUID/PCI identity, build/rocBLAS eligibility, physical-test status and exact
worker selector as schema-versioned JSON:

```bash
build/bin/cmfd-hip-discovery --list
build/bin/cmfd-hip-discovery --auto-select
build/bin/cmfd-hip-discovery --select 'pci:0000:0a:00.0'
```

The legacy `qualified_architectures` field is `["gfx1036", "gfx1100"]` and
means physically tested, not performance- or pool-qualified. The per-device
`compatible`/`qualified` booleans mean
that this build and its packaged rocBLAS can attempt the device safely. An
untested compatible device also reports `runtime_validation_required=true`.
If exactly one compatible device exists, the worker can auto-select it. When
integrated devices are opted in, one unique compatible dedicated GPU is still
preferred; several compatible dedicated GPUs or no unique dedicated choice
require one exact `worker_selector`. Names are never selectors. Integrated
GPUs are excluded by default and can be opted into without rebuilding:

```bash
CMFD_HIP_ALLOW_INTEGRATED=1 build/bin/cmfd-hip-discovery --list
CMFD_HIP_ALLOW_INTEGRATED=1 build/bin/cmfd-hip-discovery --select 'pci:...'
```

The original local ROCm 7.14 package exposes rocBLAS code only for `gfx1100`.
The runtime manager was therefore exercised with AMD's official `gfx103X`
package. With explicit integrated-GPU opt-in, the local `gfx1036` passed the
exact self-test and one batch32 output/inspector check without recompiling the
worker. Its 360.018-second GPU time (0.0887 effective FW/s) makes it a
functional compatibility result, not a practical mining recommendation.
Discovery inspects the selected runtime on every process start. See
[`DISCOVERY_API.md`](DISCOVERY_API.md) for the stable contract and exit codes.

## Reproducible benchmark

```bash
CMFD_BENCH_REPETITIONS=3 ./benchmarks/run_batch_sweep.sh
./benchmarks/run_batch32_qualification.sh
```

The sweep uses frozen Mainnet coefficient fixtures. For the production batch
size, use the persistent server through the official coordinator; that avoids
reloading and retransposing the 6.44 GB bank for every batch.

`run_batch32_qualification.sh` is the release-facing check. It uses the
coordinator's fixed batch size, the qualified rocBLAS solution `-1140855025`,
four persistent requests, exact SHA-256 output comparison, and the unmodified
official `cmfd-miner inspect-v4-search-batch` command.

## Pool launch

The existing wallet is encrypted and currently locked, so this launcher never
tries to read or print its key material. Supply only its public 64-hex payout
address:

```bash
CMFD_PAYOUT_ADDRESS=<64-hex-public-address> \
CMFD_POOL_URL='cmfd+tls://NUMERIC_IP:PORT?pin=64_HEX' \
./run-miner.sh
```

No pool URL is embedded or assumed. Obtain the current complete URL from the
operator through an authenticated channel. Before starting, `run-miner.sh`
connects to the numeric endpoint, hashes the presented leaf certificate and
requires an exact match with the URL pin. It also verifies the official model
bank size and SHA-256 and runs the HIP self-test.

The launcher then uses the official `v1.0.13` `cmfd-miner` coordinator, the
pinned pool certificate, the official model bank and the local HIP worker. The
project-local `nvidia-smi` shim is limited to satisfying the coordinator's
NVIDIA-only discovery gate; it does not emulate CUDA or participate in proof
calculation. Its UUID and telemetry fields are placeholders and must not be
shown as AMD measurements. It remains only for compatibility with the already
compiled coordinator; a future wallet integration should call the native HIP
discovery companion directly.

User-facing Linux launchers are in `../scripts/Mainnet_v1.0.13`:

- `05_MINAGE_AMD_POOL.sh` performs the guarded pool launch and keeps a private
  log under `logs/pool`.
- `06_MINAGE_AMD_SOLO.sh` deliberately refuses to start because the full AMD
  solo prover is not available.
- `07_TEST_AMD.sh` verifies hardware, dependencies, source invariants, the
  model and the short exact self-test by default. Use `--qualification` only
  when an explicit reproducible batch-32 performance/output check is wanted;
  `--quick` remains an accepted compatibility alias for the safe default.

## Support boundary

Pool replay/search is production-qualified only on the RX 7900 XTX
(`gfx1100`). The local `gfx1036` has exact real-hardware batch evidence but no
pool or useful-throughput claim. Other packaged architectures remain candidates until their
rocBLAS package, startup self-test, exact batch-32 output and real hardware are
validated. The `gfx1100` path retains HIP Graphs, masks, pinned buffers and
solution `-1140855025`; other architectures default to rocBLAS standard
selection instead of reusing a `gfx1100` solution ID. One worker selects one
GPU; concurrent multi-GPU orchestration is not included. Solo remains
unsupported because `real_bank0_relations` still depends on the official
SP1/CUDA prover path.

## Reports

- [`analysis/COMMON_FOUNDRY_BASELINE.md`](../../../analysis/COMMON_FOUNDRY_BASELINE.md)
- [`analysis/COMMON_FOUNDRY_OPTIMIZATION_RESULTS.md`](../../../analysis/COMMON_FOUNDRY_OPTIMIZATION_RESULTS.md)
- [`analysis/COMMON_FOUNDRY_AMD_FINAL.md`](../../../analysis/COMMON_FOUNDRY_AMD_FINAL.md)
- [`FOUNDER_HANDOFF.md`](FOUNDER_HANDOFF.md)
- [`WALLET_INTEGRATION_GUIDE.md`](WALLET_INTEGRATION_GUIDE.md)
- [`AMD_HIP_INTEGRATION_REPORT.md`](AMD_HIP_INTEGRATION_REPORT.md)
- [`RELIABILITY_FINALIZATION.md`](RELIABILITY_FINALIZATION.md)
- [`benchmarks/qualification/2026-10-12-QUALIFICATION.md`](benchmarks/qualification/2026-10-12-QUALIFICATION.md)
- [`benchmarks/qualification/2026-10-14-MULTIARCH.md`](benchmarks/qualification/2026-10-14-MULTIARCH.md)
- [`benchmarks/qualification/2026-10-15-DEPLOYMENT.md`](benchmarks/qualification/2026-10-15-DEPLOYMENT.md)
- [`LINUX_DEPLOYMENT.md`](LINUX_DEPLOYMENT.md)

No consensus rule, target check, share format, wallet logic or pool protocol is
modified by this worker.
