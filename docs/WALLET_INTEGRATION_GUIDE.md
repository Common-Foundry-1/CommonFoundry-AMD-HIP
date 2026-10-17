# Common Foundry wallet integration guide (v1.0.13)

This guide maps the AMD HIP contribution to official source commit
`54b127b296eb2019c623fa8ac4ddff5f78516a7c`. The official source tree was
inspected but is not modified by this contribution. AMD support requires a
small wallet/coordinator adaptation; the existing NVIDIA-only binary cannot
consume native AMD discovery by itself.

## What the Mining view actually consumes

`apps/wallet/src/components/MiningView.tsx` reads `MiningStatus` through
`useMiningData` and `miningClient`. In pool mode the visible values and their
sources are:

| UI value | `MiningStatus` field | Real producer |
| --- | --- | --- |
| Current work rate | `matrix_attempts_per_second` | Rust coordinator: completed attempts divided by batch wall time. |
| Accepted shares | `shares_accepted` | Pool `ShareResult.accepted`, counted by the Rust coordinator. |
| Rejected shares | `shares_rejected` | Pool `ShareResult.accepted == false`, counted by the coordinator. |
| Pool blocks | `blocks_found` | Pool `ShareResult.block_accepted`. |
| Credited Mainnet atoms | `credited_atoms` | Pool session accounting received by the coordinator. |
| Pool connection | `pool_connected` | Coordinator connection state. |
| Session attempts | `session_attempts` | Attempts returned by persistent search batches, accumulated by Rust. |
| Pool height | `current_height` | Current pool job challenge height minus one. |
| Lifecycle/error/stage | `lifecycle`, `last_error`, `stage` | Wallet mining manager. |
| Engine/device identity | `engine`, `device` | Backend choice and discovery result retained by the wallet. |

The HIP worker owns the selected device identity, initialization errors,
batch execution and final-activation output. It does not own pool state. Do
not add accepted/rejected/credit/connection fields to the worker protocol.
The current view has no temperature, power, live-VRAM or efficiency panel.

## Existing launch path

1. `runtime.rs::start_embedded_node` resolves packaged ProductionV4 artifacts
   and currently hard-codes `cmfd-v4-replay` into
   `ProductionV4PoolSearchAssets`.
2. `mining.rs::start_production_v4_pool_searcher` calls
   `production_v4_pool_searcher_config` with batch size 32.
3. `production_v4_pool.rs` builds an absolute worker command and starts a
   persistent child with piped stdin/stdout.
4. The coordinator waits for `CMFD_V4_REPLAY_READY`, sends `RUNBATCH`, waits
   for `CMFD_V4_REPLAY_DONE`, and sends `QUIT` during teardown.
5. `mine_production_v4_pool_connection` owns the pool job cursor, rate,
   submission and session counters.

On native Linux, `production_v4_pool_searcher_config(..., None, None)` does not
set `CUDA_VISIBLE_DEVICES`. Therefore the existing persistent worker contract
already works for HIP. The remaining changes are backend discovery, packaged
worker resolution, a HIP selector argument and neutral status wording.

## Minimal founder-side changes

### 1. Package, prepare and discover the backend

Package these three executables beside the authenticated ProductionV4 assets:

- `cmfd-hip-runtime`
- `cmfd-v4-hip-replay`
- `cmfd-hip-discovery`

During wallet startup on Linux, first spawn `cmfd-hip-runtime status`. If it
reports `authorization_required`, show the official artifact, byte count and
destination to the user, then call `prepare --authorize-download` only after
explicit consent. Treat `system_authorization_required`, `unsupported_architecture`,
`driver_unavailable`, `permission_denied` and download/integrity errors as
distinct setup failures. Progress is JSON on stderr and the single final
result is JSON on stdout. A ready installation is reused on later launches
without network access, compilation or reinstallation.

Then spawn `cmfd-hip-discovery --auto-select`, parse one JSON object, require
schema/version/backend exactly, require exit code 0, and retain
`selection.worker_selector`, `selection.name` and `selection.architecture`.
Also retain the top-level `runtime` object so setup failures identify the
actual selected root and version. Do not parse console text or call
`nvidia-smi` for the HIP path.

If discovery identifies one intended device whose sole blocking reason is
`rocblas_architecture_unavailable`, repeat preparation once with its exact
reported target, for example `prepare --architecture gfx1036` (plus
`--authorize-download` only after consent), then rerun discovery. The supplied
Linux launchers implement this recovery. Do not derive the target from a
marketing name, loop indefinitely, or download when discovery is ambiguous.

Also retain or inspect `compatible`, `physically_tested`,
`runtime_validation_required`, `qualification`, `integrated` and
`worker_selector` for every device. `architecture_compiled` alone is not
permission to launch: rocBLAS, memory, workgroup and policy checks must also
pass. The legacy `qualified_architectures` array means physically tested,
while per-device `qualified` remains a compatibility alias of
`compatible`.

If several compatible dedicated AMD GPUs exist, `--auto-select` intentionally
fails. With integrated opt-in, exactly one compatible dedicated GPU is
preferred over compatible integrated devices; the latter remain explicitly
selectable. Call `--list`, display every compatible identity and persist one
exact `uuid:` or `pci:` selector whenever the choice remains ambiguous. Until
such a selector UI exists, return a clear setup error rather than choosing GPU
0 or starting every GPU.

The backend safe default excludes integrated GPUs. A product policy may opt in
by setting `CMFD_HIP_ALLOW_INTEGRATED=1` for both discovery and worker
processes. This is one boolean product preference, not a benchmark/tuning UI.
The original system runtime exposed only `gfx1100` rocBLAS code. The manager
can select the official `gfx103X` user-space family for a `gfx1036` device.
The local iGPU passed the exact self-test and one batch32 output check, but at
only 0.0887 effective FW/s and without a pool run. Product metadata must keep
that functional evidence separate from the `gfx1100` production/pool claim.
Integrated opt-in and the calculated memory reserve still apply.

### 2. Represent the backend without regressing CUDA

In `apps/wallet/src-tauri/src/mining.rs`, extend `MiningEngine` from
`Cpu/Cuda` to `Cpu/Cuda/Hip`. Mirror that in
`apps/wallet/src/mining/types.ts` as `"cpu" | "cuda" | "hip"`.

Add a backend descriptor to `ProductionV4PoolSearchAssets`, conceptually:

```rust
enum ProductionV4SearchBackend {
    Cuda { device_label: String },
    Hip { device_label: String, selector: String },
}
```

Keep the existing CUDA resolution as the default/fallback policy selected by
the project owner. Only construct `Hip` from a successful schema-checked
discovery response. Do not change NVIDIA solo selection: AMD remains pool-only
because this contribution has no ProductionV4 proof worker.

### 3. Pass the exact HIP selection to the worker

After `production_v4_pool_searcher_config` creates the native Linux command,
insert these two arguments into `config.replay.arguments` for `Hip`:

```text
--device-selector <selection.worker_selector>
```

The current worker parser accepts options before or after `--server`; placing
them before `--server` is clearest. Do not translate a HIP index into
`CUDA_VISIBLE_DEVICES`. Preserve the existing CUDA environment handling and
WSL arguments for NVIDIA.

For a cleaner long-term API, `production_v4_pool_searcher_config` may accept a
backend-specific `ProductionV4PoolWorkerCommand` directly. That refactor is
optional; it is not required to integrate the HIP worker on native Linux.

### 4. Retain real identity in status

`mine_production_v4_pool_connection` currently overwrites the device label
with `Persistent ProductionV4 CUDA batch search`. Replace that constant with
the selected backend engine and real `device_label` retained in the assets or
searcher state:

```rust
current.engine = MiningEngine::Hip;
current.device = Some(format!("{name} ({architecture})"));
```

The shown value is an example assembled from discovery; do not hard-code it.
Do not expose UUID or PCI identity in the UI unless the product explicitly
needs it.

### 5. Make existing copy backend-neutral

`MiningView.tsx` currently treats only `engine === "cuda"` as accelerated and
hard-codes “CUDA”/“NVIDIA” in its ProductionV4 pool copy. Define an
`acceleratorActive` check for CUDA or HIP and choose a label from `engine`.
The layout and all existing pool metrics can remain unchanged. No new panel is
required.

The smallest visible changes are:

- “HIP engine” when `engine === "hip"`;
- “HIP ProductionV4 pool search” in the disclosure copy;
- the real `device` label where appropriate;
- current CUDA wording unchanged for NVIDIA.

### 6. Keep lifecycle and pool accounting unchanged

Reuse the current `MiningManager::start`, `stop_inner`, pool reconnect loop and
`PersistentWorker` supervision. The v1.0.13 `Drop` path sends `QUIT`, flushes,
then calls `kill` and `wait`; the final kill can race a graceful worker exit,
but that coordinator-owned teardown is unchanged here. In supervised server
mode, terminal `SIGINT` is logged and deferred to this coordinator-owned
`QUIT`/EOF path so an active batch is never represented by a fabricated
`DONE`. `SIGTERM`, `SIGHUP`, command errors and engine errors remain immediate
nonzero failures. The HIP worker otherwise preserves `READY / RUNBATCH / DONE /
EVICT / QUIT`. No pool protocol, nonce, target, share or consensus code needs
to change.

## Suggested tests in the official repository

- Extend `MiningView.test.tsx` with a HIP pool status while retaining its
  current CUDA ProductionV4 expectation.
- Extend the `MiningStatus` fixtures in `useMiningData.test.tsx` and
  `miningClient.test.ts` for the new engine value; transport command names do
  not need to change.
- Add Rust cases beside the existing `mining.rs` ProductionV4 pool, reconnect,
  concurrent start/stop and shutdown tests.
- Deserialize schema v1 success and every structured error.
- Preserve additive schema-v1 capability fields and reject a selected device
  unless `compatible` is true.
- Exercise default and opted-in integrated policy, insufficient memory,
  missing code object and missing rocBLAS architecture.
- Reject unknown schema versions and backend names.
- Preserve CUDA selection when NVIDIA is chosen or HIP is unavailable.
- Build a HIP worker command with exactly one `--device-selector` and no CUDA
  visibility override.
- Report `MiningEngine::Hip` and the discovery label in `MiningStatus`.
- Keep pool counters sourced from mocked `PoolClientEvent::ShareResult`.
- Ensure AMD is offered only for pool, while existing NVIDIA solo behavior is
  unchanged.
- Exercise start, stop, unexpected worker exit and one reconnect.

## Temporary compatibility layer

`tools/nvidia-smi` remains only for the already-built v1.0.13 standalone
coordinator, which refuses to start an external worker without NVIDIA-shaped
discovery. Its UUID and zero sensor fields are synthetic. They must never be
mapped into `MiningStatus` or presented as AMD telemetry. Remove this shim
from an official wallet integration once native discovery is wired in.
