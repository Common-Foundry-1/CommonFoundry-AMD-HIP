# Linux deployment and runtime qualification — 2026-10-15

## Scope and invariants

This pass finalized the Linux distribution path around the already-qualified
ProductionV4 HIP engine. It did not modify the replay kernels, signed-INT8
semantics, Goldilocks reduction, final-activation encoding, HIP Graph path,
pinned buffers, precomputed masks or the `gfx1100` batch32 rocBLAS solution
`-1140855025`. It did not connect to a pool, add AMD solo support, modify the
official wallet, or touch wallet/Mainnet data.

The reference remains Common Foundry v1.0.13 source commit
`54b127b296eb2019c623fa8ac4ddff5f78516a7c`, model size 6,442,975,416 bytes
and model SHA-256
`5f9b213c3bda51b74e4ebabb26607b67385d613aa8d99af915a48ab063e17d4e`.

## Deployment result

The prebuilt package now contains a 21-target worker, runtime-aware discovery,
worker/discovery wrappers, a versioned ROCm 7.14 catalog, a private runtime
manager, cached model verification, sources, deterministic tests, integration
scripts and documentation. Installed binaries use only relative install
`RUNPATH` entries. No ROCm payload, model, private log, wallet data or secret
is embedded.

The runtime manager was validated for missing/complete/incomplete ROCm,
missing rocBLAS architecture, explicit consent, interrupted/resumed downloads,
corruption, offline bundles, atomic updates, rollback, version/GPU changes,
concurrent preparation, selected library paths and model-cache invalidation.
A successful download is now atomically renamed out of `.part`; interrupted
downloads alone retain that suffix.

Two consecutive package builds were byte-identical after removing variable
PAX access/change-time metadata. Package contents and every included file are
covered by `SHA256SUMS`; the outer archive receives its own `.sha256` file.

## Official gfx103X first-run exercise

The manager downloaded the version-pinned AMD ROCm 7.14.0 `gfx103X-all`
archive from the catalogued official HTTPS object:

- declared and observed bytes: 2,397,294,419;
- observed SHA-256:
  `ce9a5be2b43ee1bdd85de3fa9ea3c3d5dcb6875445acf7281c3763a4ee783f19`;
- installed privately with state/runtime directories mode `700` and manifests
  mode `600`;
- quick and deep runtime verification: pass;
- rocBLAS payloads discovered: `gfx1030` through `gfx1036`.

AMD does not publish an adjacent detached SHA-256/signature for this family
archive. The manager therefore also pins HTTPS origin, exact length and S3
object version, computes SHA-256 before extraction and records it for reuse.
This is not represented as an AMD signature.

## Real hardware results

No Common Foundry miner/worker process was active before either short test.

### Integrated AMD Radeon Graphics (`gfx1036`)

The private `gfx103X` runtime made the real PCI-selected iGPU compatible only
with explicit `CMFD_HIP_ALLOW_INTEGRATED=1`. Results:

- exact startup differential self-test: pass;
- memory preflight: 16,103,043,072 free HIP bytes and 19,211,497,472 available
  system bytes against the 7,767,843,456-byte engine floor plus 2 GiB system
  reserve;
- model load: 4.676 seconds;
- one ProductionV4 batch32, rocBLAS standard `solution=0`: 360.018094 seconds
  GPU, 360.849619 seconds wall;
- throughput: 0.088884 GPU FW/s, 0.088680 effective FW/s;
- output: 67,108,864 bytes, SHA-256
  `fe67b80af4671210cd33306d0976c7dbb285dd55203d8eff733866cd7ef4a7a7`;
- official v1.0.13 inspector: consumed 32 nonces, `qualified=false` for the
  frozen target, with no encoding/replay error;
- protocol: `READY`, `DONE`, diagnostic sequence and `QUIT` exit all clean.

This proves exact functional compatibility on this particular `gfx1036`. Its
throughput is not practical for mining, and no real-pool claim is made.

### AMD Radeon RX 7900 XTX (`gfx1100`)

A two-request non-regression retained `solution=-1140855025`, HIP Graphs and
the exact reference output on both requests. The warm second request measured:

- 2.041688 seconds GPU, 2.064087 seconds wall;
- 15.673302 GPU FW/s;
- 15.503225 effective FW/s;
- output SHA-256 identical to the reference;
- official inspector and clean `DONE`/`QUIT`: pass.

The first request measured 15.575936 GPU and 15.162879 effective FW/s and
includes first-workspace/graph effects. These short results are consistent
with the retained qualification range; they are not a new tuning campaign.

## Automated validation

- release build: pass for all 21 configured code objects;
- CTest: 5/5 suites pass;
- discovery fixture coverage: 17 cases;
- runtime manager/launcher: 22 deterministic cases, network/GPU simulated;
- model integrity cache: 3 cases;
- shell syntax checks: pass;
- install layout and relative `RUNPATH`: pass;
- package inventory and byte-for-byte reproducibility: pass;
- real `gfx1100` and `gfx1036` discovery/selectors: pass.

Final package verification on 2026-10-16 additionally extracted the tarball
outside the repository, verified every internal `SHA256SUMS` entry, confirmed
the relative `RUNPATH`, executed the packaged coordinator shim, and ran the
installed `07_TEST_AMD.sh --quick` path successfully on both the system
`gfx1100` runtime and the private `gfx103X`/`gfx1036` runtime. The installed
launcher's one-time missing-rocBLAS recovery also passed with controlled fake
dependencies. No batch or pool session was repeated for these path-only
changes.

## Remaining limits

- Production/pool qualification remains `gfx1100`; `gfx1036` has functional
  exact-batch evidence only.
- Other catalogued architectures are packaged candidates, not physical claims.
- `gfx906` remains in the worker but has no ROCm 7.14 family artifact in this
  release catalog.
- The universal runfile clean-machine path is deterministically tested, but a
  destructive clean-OS reinstall was not performed on this workstation.
- AMD solo proving and simultaneous multi-GPU orchestration remain out of
  scope.
- No new pool session was run because no current operator-authenticated pinned
  endpoint was supplied; the historical URL was deliberately not reused. The
  earlier authenticated Mainnet evidence is preserved unchanged, including
  its documented unclean final pipe event.

## Founder/end-user sequence

The wallet should run `cmfd-hip-runtime status`, request consent only when the
structured result requires a download, run `prepare --authorize-download`,
then run `cmfd-hip-discovery --auto-select` or retain an explicit selector.
The worker is started only after those checks. Later starts reuse the verified
runtime and model cache without network access or compilation. Pool counters
remain owned by the official coordinator.
