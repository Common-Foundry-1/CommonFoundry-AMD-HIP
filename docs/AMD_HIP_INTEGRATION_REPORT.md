# AMD HIP integration report — updated 2026-10-16

## Result

The ProductionV4 HIP search engine is preserved and now has a
multi-architecture build, capability-driven discovery and a deployable Linux
runtime boundary. On the local machine it enumerates the discrete `gfx1100`
and integrated `gfx1036`. The system runtime qualifies `gfx1100`; the private
official AMD `gfx103X` runtime makes `gfx1036` eligible with explicit
integrated opt-in. Both architectures passed the exact real-hardware batch32
check, but only `gfx1100` is production/pool qualified and performant. No
official wallet source, consensus code, wallet data, Mainnet data or solo
prover was modified. The original integration was delivered in `e6eef419`;
lifecycle reliability in `cc776e02`; this report records the subsequent
multi-architecture and deployment finalization.

## Files added

- `src/cmfd_hip_discovery.hpp`: stable discovery/selection data model.
- `src/cmfd_hip_discovery.cpp`: dynamically loaded HIP enumeration, exact
  selectors, qualification policy and JSON encoder.
- `src/cmfd_hip_discovery_cli.cpp`: one-object JSON command-line interface.
- `tests/discovery_tests.cpp`: fixture tests for selection and failures.
- `tests/validate_discovery_json.py`: strict JSON parsing for every fixture and
  the live discovery response.
- `DISCOVERY_API.md`: schema, commands and exit-code contract.
- `WALLET_INTEGRATION_GUIDE.md`: exact v1.0.13 Rust/TypeScript integration
  points and ownership of Mining status fields.
- `AMD_HIP_INTEGRATION_REPORT.md`: this validation record.

## Files modified

- `CMakeLists.txt` and `build.sh`: build a configurable 21-target HIP fat
  binary; the selected runtime is now inspected at launch for rocBLAS support.
- `src/cmfd_v4_hip_replay.hip`: startup-only selector resolution and
  capability/memory guard, mandatory exact startup self-test and
  architecture-scoped rocBLAS solution policy. Compute kernels, arithmetic and
  replay protocol are unchanged.
- `cmfd-v4-hip-worker`: optional `CMFD_HIP_DEVICE_SELECTOR` forwarding while
  retaining legacy `CMFD_HIP_DEVICE`.
- `run-miner.sh`, `test.sh`,
  `../scripts/Mainnet_v1.0.13/05_MINAGE_AMD_POOL.sh` and
  `../scripts/Mainnet_v1.0.13/07_TEST_AMD.sh`: remove model/`gfx1100`
  assumptions and resolve the exact native selector before launch.
- `README.md` and `FOUNDER_HANDOFF.md`: current integration and pool evidence.

Scripts `01` through `04` and the solo refusal `06` are unchanged. The
temporary `tools/nvidia-smi` shim is unchanged.

## Rebuild and test

```bash
cd CommonFoundry/Linux/AMD_HIP_Lab
./build.sh
ctest --test-dir build --output-on-failure
cmake --install build --prefix /absolute/output/directory
build/bin/cmfd-hip-discovery --list
build/bin/cmfd-hip-discovery --auto-select
build/bin/cmfd-v4-hip-replay --self-test
./benchmarks/run_batch32_qualification.sh
```

Select an exact device with the value returned as `worker_selector`:

```bash
build/bin/cmfd-hip-discovery --select 'pci:DOMAIN:BUS:DEVICE.FUNCTION'
build/bin/cmfd-v4-hip-replay \
  --device-selector 'pci:DOMAIN:BUS:DEVICE.FUNCTION' \
  --self-test
```

## Discovery validation

Automated fixture coverage passes for:

1. one qualified device;
2. multiple devices and explicit selection;
3. qualified device with no UUID/PCI identity;
4. no devices;
5. missing HIP runtime;
6. integrated compatible device allowed and excluded by policy;
7. two compatible dedicated devices;
8. one compatible plus one incompatible device;
9. insufficient memory and unsupported workgroup;
10. architecture absent from the binary;
11. architecture absent from packaged rocBLAS;
12. invalid/ambiguous selector;
13. simulated HIP and rocBLAS initialization errors;
14. valid JSON for all expected results and both policy modes.

Live validation found one `gfx1100` discrete GPU and one `gfx1036` integrated
device. Both are in the compiled architecture manifest, report 1024-thread
workgroup support and exceed the calculated 7,767,843,456-byte floor. With
the original system runtime, `--auto-select` selected `gfx1100` and `gfx1036`
correctly reported `rocblas_architecture_unavailable`. With the private
official `gfx103X` runtime and explicit integrated opt-in, discovery instead
selected the real `gfx1036` PCI identity. Both devices passed the exact
self-test through their own selectors.

## Cryptographic and performance validation

The rebuilt worker passed:

- exact signed-INT8 GEMM differential test;
- initialization and reduction kernel checks;
- canonical field arithmetic checks;
- persistent `READY / RUNBATCH / DONE / EVICT / QUIT` execution;
- four batch-32 outputs checked by the official v1.0.13 inspector;
- rocBLAS solution `-1140855025` retained;
- output size 67,108,864 bytes and SHA-256
  `fe67b80af4671210cd33306d0976c7dbb285dd55203d8eff733866cd7ef4a7a7`
  on all four runs.

The three warm qualification requests averaged 15.557 GPU FW/s and 15.444
effective FW/s. The prior independent qualification averaged 15.638 and
15.511 respectively. The change is approximately -0.5% GPU and -0.4%
effective, within run-to-run variation and not a material regression. The
discovery code runs only before device initialization and does not poll during
batches.

The CMake install rule and reproducible package were exercised into temporary
prefixes. They install the native worker/discovery plus their wrappers,
runtime manager, artifact catalog and verifiers. Install `RUNPATH` is relative
and discovery has no loader-time dependency on `libamdhip64`, which permits a
structured missing-runtime response.

## 2026-10-15 deployment and gfx1036 result

The first-run manager downloaded the official version-pinned 2,397,294,419-byte
`gfx103X-all` archive, computed SHA-256
`ce9a5be2b43ee1bdd85de3fa9ea3c3d5dcb6875445acf7281c3763a4ee783f19`,
installed it atomically outside `/opt/rocm`, and passed deep verification. The
local `gfx1036` then completed one exact batch32 in 360.018 seconds GPU time
at 0.0887 effective FW/s. Its 67,108,864-byte output retained SHA-256
`fe67b80a…f4a7a7`, and the official inspector consumed all 32 nonces without
encoding or replay error. This is functional hardware evidence, not a
practical-performance or pool claim.

A two-request `gfx1100` non-regression retained the exact output. Its warm
request measured 15.673 GPU FW/s and 15.503 effective FW/s with solution
`-1140855025`. Full evidence is in
`benchmarks/qualification/2026-10-15-DEPLOYMENT.md`.

## Existing real Mainnet pool evidence

The private local log `logs/pool/pool-20261013T005249Z.log` was read in place
and remains excluded from Git. It records:

- 1,061 ProductionV4 batch-32 searches over about 40 minutes;
- 32 accepted shares, 1 rejected share and 0 stale shares in the final status;
- heights advancing from 13,863 through 13,905;
- coordinator hashrate average 15.197 FW/s over 353 status samples;
- HIP average 15.668 GPU FW/s and 15.548 effective FW/s over the batch lines;
- no reconnect marker in that log.

The same log ends with the coordinator reporting that the replay worker closed
stdout before a final `DONE` marker while its status was still unknown. The
accepted-share evidence before that point is valid, but the ending was not a
clean stop and should not be represented as indefinite stability. No new pool
session was launched during this discovery pass; the authenticated historical
session is reused as requested.

The shim-reported `GPU-000...` identity and `0 W`/`0 C` fields in that old log
are compatibility placeholders, not measurements. Native discovery returns
the real HIP identity and does not expose fabricated sensors.

## MiningView ownership and founder work remaining

`MiningView.tsx` needs the coordinator-owned rate, attempts, pool height,
connection state, shares, blocks and credited atoms already present in
`MiningStatus`. The HIP backend adds only real engine/device identity and
worker errors. The founder must:

1. package and invoke `cmfd-hip-discovery` on Linux;
2. add `Hip`/`"hip"` to the Rust and TypeScript `MiningEngine` enums;
3. resolve the HIP replay executable and pass `--device-selector`;
4. retain the real device label instead of the hard-coded CUDA label;
5. make existing Mining view copy CUDA/HIP-aware;
6. preserve CUDA/WSL and NVIDIA solo paths unchanged;
7. offer AMD only for ProductionV4 pool search.

No pool field should be copied from worker output. No detailed sensor panel or
new UI layout is required.

## Known limits

- `gfx1100` is production/pool qualified. `gfx1036` is physically tested for
  exact function but, at 0.0887 effective FW/s and without a pool session, is
  not a practical mining or pool-qualified target. The fat binary embeds 21
  targets; all others still require matching rocBLAS and real hardware tests.
- One worker selects one GPU. Concurrent multi-GPU orchestration is not part
  of this contribution.
- AMD solo proof generation is not implemented.
- The compiled v1.0.13 standalone coordinator still requires the temporary
  NVIDIA compatibility shim; native discovery requires founder-side code.
- The existing pool log's unclean final worker-pipe error has no identifiable
  root cause in the retained evidence. Targeted signal, EOF, marker-flush and
  nonzero-error diagnostics now make a future occurrence distinguishable; see
  `RELIABILITY_FINALIZATION.md`.
- No new real-pool run was necessary or performed in this pass.
