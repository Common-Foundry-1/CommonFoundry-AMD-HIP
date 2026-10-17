# Common Foundry AMD HIP backend handoff

## Purpose

This package is an open-source AMD HIP replay/search backend for the Common
Foundry Mainnet `v1.0.13` ProductionV4 pool coordinator. It preserves the
official coordinator, pool protocol, share inspection, target comparison and
server-side verification. It does not modify the graphical wallet or the
consensus implementation.

The implementation is based on release tag `v1.0.13`, source commit
`54b127b296eb2019c623fa8ac4ddff5f78516a7c`.

## Why this contribution targets Linux

Linux x86-64 is the product boundary because this worker, ROCm 7.14 package
flow, native `amdgpu`/`/dev/kfd` access, device permissions, diagnostics and
official coordinator contract were all exercised there. Limiting the first
integration to that qualified path reduces platform-specific loader, driver
and packaging risk for the founder. This is not a claim that HIP Graphs or
pinned memory are Linux-only, nor that Linux is inherently faster than an
unmeasured Windows implementation. Windows packaging is simply outside the
evidence and scope of this contribution.

## Contribution contents

- `src/cmfd_v4_hip_replay.hip`: HIP/rocBLAS replay implementation.
- `src/cmfd_hip_worker_protocol.{hpp,cpp}`: exact persistent command parsing,
  marker flushing and termination diagnostics.
- `src/cmfd_hip_discovery.{hpp,cpp}` and
  `src/cmfd_hip_discovery_cli.cpp`: native HIP inventory, qualification and
  schema-versioned JSON selection interface.
- `CMakeLists.txt` and `build.sh`: reproducible, configurable
  multi-architecture fat binary with portable install `RUNPATH`.
- `runtime/cmfd-hip-runtime` and `runtime/packages-v1.tsv`: first-run
  preparation, private atomic install, cache/rollback and official AMD 7.14
  artifact catalog.
- `cmfd-v4-hip-worker`: coordinator-facing wrapper.
- `tools/nvidia-smi`: narrow compatibility response for the coordinator's
  NVIDIA-only discovery gate. It is not used for telemetry or computation.
- `tools/verify-pool-tls.sh`: exact leaf-certificate pin preflight.
- `fixtures/`: frozen official Mainnet template and coefficient fixtures.
- `benchmarks/run_batch32_qualification.sh`: persistent exact batch-32 test.
- `benchmarks/results/*.csv`: optimization and profiler summaries.
- `benchmarks/qualification/`: final local logs and qualification report.
- `tests/`: simulated selection/error coverage, strict JSON validation and
  automated worker lifecycle tests.
- `DISCOVERY_API.md`: discovery schema and stable exit-code contract.
- `WALLET_INTEGRATION_GUIDE.md`: precise v1.0.13 wallet integration map.
- `LINUX_DEPLOYMENT.md`: complete first/second launch and distribution contract.
- `../scripts/Mainnet_v1.0.13/05_MINAGE_AMD_POOL.sh`: guarded pool launcher.
- `../scripts/Mainnet_v1.0.13/06_MINAGE_AMD_SOLO.sh`: explicit solo refusal.
- `../scripts/Mainnet_v1.0.13/07_TEST_AMD.sh`: end-user diagnostic.

Generated binaries, the 6.44 GB model bank, scratch files, wallet files and
private runtime logs are intentionally excluded.

## Build requirements

- Linux x86-64.
- ROCm/HIP 7.14.1 in the qualified environment.
- rocBLAS and `amdhip64` from the same ROCm installation.
- CMake 3.21 or newer and a C++20 compiler.
- At least 7,767,843,456 free HIP bytes, derived from the real batch32
  allocations plus a 768 MiB safety allowance; integrated GPUs additionally
  retain a 2 GiB system-memory reserve.
- AMD Radeon RX 7900 XTX, architecture `gfx1100`, 24 GiB VRAM for the
  physically qualified reference.
- Official `v1.0.13` `MODEL-V2.bank`, 6,442,975,416 bytes, SHA-256
  `5f9b213c3bda51b74e4ebabb26607b67385d613aa8d99af915a48ab063e17d4e`.

Maintainer build and test:

```bash
./build.sh
./test.sh
./benchmarks/run_batch32_qualification.sh
```

End users receive the prebuilt package and do not need a compiler. On first
launch the wallet calls `cmfd-hip-runtime status`, requests consent only if an
official AMD user-space artifact is needed, then calls
`prepare --authorize-download`. Later starts reuse the validated private or
system runtime without downloading, compiling or modifying global ROCm. See
`LINUX_DEPLOYMENT.md` for the complete atomic install, integrity, rollback and
offline-bundle contract.

Native device inventory and safe auto-selection:

```bash
build/bin/cmfd-hip-discovery --list
build/bin/cmfd-hip-discovery --auto-select
```

The companion dynamically loads HIP and always emits one JSON object,
including for missing-runtime and discovery failures. It enumerates every HIP
device and reports independently whether the architecture is in the binary,
rocBLAS supports it, ProductionV4 memory/workgroup requirements pass, the
integrated policy permits it and the architecture was physically tested. UUID
is preferred, PCI topology is the fallback and a prefixed HIP index is
session-scoped. Multiple compatible devices require explicit selection.

The default fat binary embeds 21 compiler-supported targets from `gfx906`
through `gfx1201`; packagers can override `CMFD_HIP_ARCHITECTURES`.
Discovery inspects the rocBLAS code objects in the runtime selected on the
current computer, so installing a compatible architecture never requires
recompiling the worker. The old configure-time rocBLAS snapshot has been
removed. Physical qualification remains separate. Integrated devices default off and use
`CMFD_HIP_ALLOW_INTEGRATED=1` as an explicit opt-in.

## Worker interface

Start the persistent process with:

```text
cmfd-v4-hip-replay --server /absolute/path/to/MODEL-V2.bank
```

The protocol is line-oriented:

- Worker emits `CMFD_V4_REPLAY_READY` after loading the model.
- Coordinator sends four tab-delimited fields:
  `RUNBATCH<TAB>COUNT<TAB>COEFFICIENTS<TAB>OUTPUT_PREFIX`.
- Worker writes `OUTPUT_PREFIX-final-activation.bin` and emits
  `CMFD_V4_REPLAY_DONE`.
- Coordinator may send `EVICT` to release model/workspace memory.
- `QUIT` terminates the worker.

The v1.0.13 pool coordinator fixes `COUNT` at 32. On `gfx1100`, the
qualified rocBLAS solution is `-1140855025`, with runtime fallback if it is
unavailable. Other architectures default directly to standard rocBLAS
selection, so a `gfx1100` solution ID is never imposed on them. Exact signed
INT8 accumulation, Goldilocks field
reduction, final limb encoding and the official output naming remain intact.

## Preserved optimizations

- Batch-specific rocBLAS solution selection, including batch 32
  `-1140855025`.
- Pinned host output buffers.
- Captured HIP Graph execution.
- Precomputed coordinate masks and model weight biases.
- Bounded pseudo-Mersenne field reduction.
- Elimination of dead intermediate stores.

## Verified result

On the qualified RX 7900 XTX, the final four-request persistent batch-32 run
produced the same 64 MiB output each time. SHA-256 was
`fe67b80af4671210cd33306d0976c7dbb285dd55203d8eff733866cd7ef4a7a7`.
The official inspector consumed all 32 nonces and returned
`qualified=false`, meaning no frozen-fixture nonce met the target; it did not
report an encoding or replay error.

After the first workspace/graph request, three warm requests averaged:

- 15.750 FW/s measured on the GPU.
- 15.640 FW/s effective end to end.
- 2.032 seconds GPU time and 2.046 seconds wall time per batch.

An independent end-to-end execution of the packaged qualification script then
averaged 15.638 GPU FW/s and 15.511 effective FW/s across its three warm
requests. Across both warm series, the observed ranges were 15.615–15.780 GPU
FW/s and 15.488–15.671 effective FW/s. Every output retained the same hash.

The qualification report and raw local logs are in
`benchmarks/qualification/2026-10-12-QUALIFICATION.md`.

After adding native discovery, a fresh four-request batch-32 qualification on
2026-10-13 retained the same hash and official-inspector result. Its three warm
requests averaged 15.557 GPU FW/s and 15.444 effective FW/s, approximately
0.5% and 0.4% below the earlier independent averages and within run-to-run
variation. Startup, exact self-test and `EVICT / QUIT` also passed. See
`AMD_HIP_INTEGRATION_REPORT.md` for the complete current validation record.

The 2026-10-14 fat-binary non-regression then measured 15.733 GPU FW/s
and 15.551 effective FW/s on its warm request, with the same exact output and
official-inspector result. The complete 21-target build manifest, `gfx1036`
rocBLAS blocker and measurements are in
`benchmarks/qualification/2026-10-14-MULTIARCH.md`.

On 2026-10-15 the new runtime manager downloaded and atomically installed the
version-pinned official AMD `gfx103X` user-space package without changing
`/opt/rocm`. The local integrated `gfx1036` then passed discovery, the exact
startup self-test and one complete batch32. It produced the same 67,108,864
bytes and SHA-256 `fe67b80a…f4a7a7`, and the official inspector consumed all
32 nonces. GPU time was 360.018 seconds and effective throughput 0.0887 FW/s.
This is real functional hardware evidence, but not a practical-performance or
pool qualification. A two-request `gfx1100` non-regression retained the exact
hash, with its warm request at 15.673 GPU FW/s and 15.503 effective FW/s. See
`benchmarks/qualification/2026-10-15-DEPLOYMENT.md`.

## Pool and solo status

Pool support is qualified both locally at the worker/coordinator seam and by an
existing authenticated Mainnet session. The private local log from 2026-10-13
records 1,061 batch-32 searches over about 40 minutes, 32 accepted shares, one
rejected share, zero stale shares and heights 13,863 through 13,905. Its HIP
batch lines average 15.668 GPU FW/s and 15.548 effective FW/s; coordinator
status averages 15.197 FW/s.

That log ends with the coordinator reporting an EOF before one final `DONE`
marker. The last HIP records prove that the GPU work, host copy, validation and
output-file flush completed, but neither the log nor the system journal records
why the process then ended. There is no evidence sufficient to call it a GPU
crash. The worker now reports normal EOF/QUIT, successful marker flushes,
command errors and termination signals with tested exit codes. See
`RELIABILITY_FINALIZATION.md`. The raw log stays private and excluded from the
contribution. The synthetic NVIDIA UUID and zero sensor values in it came from
the temporary compatibility shim and are not AMD telemetry.

Solo AMD support is unavailable. The current HIP worker covers replay/search,
not the full `real_bank0_relations` SP1 proof path. `06_MINAGE_AMD_SOLO.sh`
therefore exits without mining. A complete CUDA/SP1-to-HIP prover port is
outside this contribution.

## Integration recommendation

Treat this backend as an optional external replay worker selected only for
compatible AMD devices after its mandatory short exact startup self-test. Keep
the `physically_tested` distinction visible in release/support metadata. Keep
all official template creation, share inspection,
pool transport, target checks and server replay unchanged. Replace the
temporary `nvidia-smi` discovery shim with a native backend-capability probe in
the official coordinator before shipping AMD support broadly. The supplied
companion already provides that probe; the wallet must package it, add a HIP
engine variant, pass its exact selector to the worker and keep the real device
label. Pool statistics remain owned by the Rust coordinator. See
`WALLET_INTEGRATION_GUIDE.md` for the exact Rust/TypeScript insertion points.
