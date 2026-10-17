# AMD HIP multi-architecture finalization — 2026-10-14

## Baseline and scope

- Starting commit: `cc776e025215fa001dd70f8f674ce836d9b98c9d`.
- Official source reference remains
  `54b127b296eb2019c623fa8ac4ddff5f78516a7c`.
- Model size: 6,442,975,416 bytes.
- Model SHA-256:
  `5f9b213c3bda51b74e4ebabb26607b67385d613aa8d99af915a48ab063e17d4e`.
- No pool connection, solo work, wallet source or Mainnet state was used.

## Build and hardware classification

The ROCm 7.14 compiler successfully produced one fat worker with 21 code
objects:

`gfx906 gfx908 gfx90a gfx942 gfx1010 gfx1011 gfx1012 gfx1030 gfx1031 gfx1032 gfx1034 gfx1035 gfx1036 gfx1100 gfx1101 gfx1102 gfx1103 gfx1150 gfx1151 gfx1200 gfx1201`

`llvm-objdump --offloading` confirmed each code object in the final worker.
The installed rocBLAS library directory contains code only for `gfx1100`.
These two manifests are intentionally reported separately.

Live HIP discovery reported:

- RX 7900 XTX: `gfx1100`, discrete, 25,753,026,560 total bytes,
  1024 maximum threads per block, compiled, rocBLAS available, physically
  tested and compatible.
- AMD integrated graphics: `gfx1036`, integrated, 16,107,282,432 total
  shared-aperture bytes, 1024 maximum threads per block and compiled. With
  `CMFD_HIP_ALLOW_INTEGRATED=1`, selection stopped with
  `rocblas_architecture_unavailable` (exit 11).

The `gfx1036` test therefore stopped before model allocation and before any
fixture batch. Model load, exact output and hashrate are not available. This
is a package-specific rocBLAS limitation, not a general ban on integrated
GPUs.

## Automated and lifecycle tests

- Build: PASS.
- CTest: 3/3 PASS.
- Simulated discovery: dedicated/integrated, opt-in/default policy, multiple
  compatible devices, mixed compatible/incompatible devices, insufficient
  memory, architecture absent from binary, rocBLAS architecture absent,
  HIP/rocBLAS initialization error documents and exact selectors: PASS.
- Live JSON inventory and auto-selection: PASS.
- RX 7900 XTX exact signed-INT8/field/kernel self-test: PASS.
- Live persistent lifecycle: normal `EVICT + QUIT` exit 0, invalid command
  exit 1 and `SIGTERM` exit 143: PASS.

## RX 7900 XTX batch-32 non-regression

Two persistent requests used HIP Graphs, precomputed masks, pinned buffers and
the preserved `gfx1100` solution `-1140855025`.

| Request | GPU FW/s | Effective FW/s | Output SHA-256 |
| ---: | ---: | ---: | --- |
| 1 (workspace setup) | 15.677912 | 15.230417 | `fe67b80af4671210cd33306d0976c7dbb285dd55203d8eff733866cd7ef4a7a7` |
| 2 (warm) | 15.733294 | 15.551382 | `fe67b80af4671210cd33306d0976c7dbb285dd55203d8eff733866cd7ef4a7a7` |

The warm request is 0.14% above the prior 15.711 GPU FW/s and 0.15% above the
prior 15.528 effective FW/s, which confirms no material regression. Reported
device memory after workspace creation was 7,241,465,856 bytes used. Both
outputs were 67,108,864 bytes and the official v1.0.13 inspector consumed all
32 nonces successfully (`qualified=false` only means the frozen fixture had
no target winner).

No automatic tuning, long benchmark or real pool session was run.
