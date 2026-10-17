# AMD HIP worker reliability finalization — 2026-10-13

> Historical note: the discovery classifications quoted below describe the
> `cc776e02` single-architecture build. The 2026-10-14 multi-architecture
> build replaces `architecture_not_qualified` with explicit compiled,
> rocBLAS, memory and integrated-policy states; see
> `benchmarks/qualification/2026-10-14-MULTIARCH.md`.

## Scope and conclusion

This follow-up starts from commit `e6eef419` and changes only the AMD worker's
persistent-command boundary, tests and documentation. The HIP kernels,
ProductionV4 arithmetic, rocBLAS solution selection, pinned buffers, HIP
Graphs, masks, output bytes and pool protocol markers are unchanged. No
official wallet, CPU backend, CUDA worker, Mainnet data or solo path was
modified.

The historical pool session ended with a real stdout EOF before one final
`CMFD_V4_REPLAY_DONE`, but the available evidence does not identify why the
process ended. In particular, it does not establish a GPU crash.

A later 2026-10-16 pool session identified a separate, reproducible shutdown
cause. A terminal `Ctrl+C` delivered `SIGINT` to both the official coordinator
and its worker process. The worker's async-signal-safe handler immediately
called `_exit(130)`, so the coordinator observed stdout EOF before the next
`DONE` and reported replay failure. The preceding batch and three accepted
shares were complete; this was an operator shutdown race, not a cryptographic,
GPU or share-validation failure.

## Historical log evidence

`logs/pool/pool-20261013T005249Z.log` is private and remains ignored. Its final
successful work records are:

- line 2503: a complete batch-32 GPU timing record;
- line 2504: final activations copied to the host, validated and flushed to
  disk;
- line 2505: the coordinator reports EOF before the corresponding `DONE`, with
  `status=None`.

The failure is therefore confined to the narrow interval after output-file
completion and before the coordinator received the flushed stdout marker. The
log has no `CMFD_HIP_ERROR`, HIP runtime error, rocBLAS error, model eviction,
reconnect, OOM, reset, abort or signal record. The system kernel journal has no
entry in the surrounding 2026-10-12 21:32:30–21:34:00 local interval.

In the v1.0.13 coordinator, EOF is followed immediately by `Child::try_wait`.
Its `status=None` means no exit status was available at that instant; it is not
a diagnosis of the exit. The wrapper uses `exec`, so there is no resident shell
between the coordinator and HIP executable. An external signal, process exit
or other asynchronous termination cannot be distinguished retrospectively
because the old worker had no signal diagnostic. The root cause remains
unknown.

## Demonstrable protocol defects corrected

Two independent issues were present even though neither can be claimed as the
cause of the historical termination:

1. The coordinator writes tab-delimited fields, while the HIP worker parsed
   all whitespace. That broke otherwise valid paths containing spaces and
   diverged from the official CUDA worker contract.
2. An exception inside the old server loop printed `CMFD_HIP_ERROR`, returned
   from the loop and then let `main` return success. A failed command could
   therefore close stdout with exit code 0.

The protocol layer now:

- parses the exact tab-delimited `RUNBATCH` contract and preserves spaces;
- validates batch counts from 1 through 64;
- emits `DONE`/`EVICTED` only after a successful handler call and verifies the
  stdout flush;
- ignores `SIGPIPE` only so a closed stdout pipe becomes a checked `EPIPE`, a
  logged `CMFD_HIP_ERROR` and exit 1 instead of an unexplained signal exit;
- lets command and engine exceptions reach the existing top-level handler,
  which logs `CMFD_HIP_ERROR` and exits 1;
- distinguishes normal `QUIT` from stdin EOF;
- records completed commands and termination reasons on stderr;
- in supervised `--server` mode, records `SIGINT` and defers shutdown to the
  coordinator, allowing the current command to emit its real marker before
  accepting `QUIT` or stdin EOF;
- retains immediate conventional exits for direct-mode `SIGINT` (130),
  `SIGTERM` (143) and `SIGHUP` (129) using an async-signal-safe handler.

No fatal GPU signals are intercepted, and no computation is retried or
silently accepted.

## Tests and live checks

Automated CPU-only protocol tests cover normal `RUNBATCH / DONE / EVICT /
QUIT`, EOF, CRLF, paths with spaces, malformed commands, invalid counts,
handler failure, supervised `SIGINT` during a simulated batch, and fatal
`SIGTERM` without a false `DONE`. Discovery fixtures cover one and several
qualified devices, explicit UUID/PCI/HIP selectors, non-qualified devices and
ambiguous auto-selection while retaining the complete inventory.

On the qualified host:

- CTest passed 3/3 tests;
- `--list` returned the qualified RX 7900 XTX and the non-qualified `gfx1036`
  iGPU;
- `--auto-select` chose only the RX 7900 XTX;
- UUID, PCI and HIP-index selectors each selected that compatible device;
- explicit selection of the `gfx1036` device failed with
  `architecture_not_qualified` and exit code 8;
- the real worker lifecycle test passed normal `EVICT + QUIT` (0), invalid
  command (1), supervised waiting-state `SIGINT + QUIT` (0), and `SIGTERM`
  (143), without running a batch or connecting to a pool;
- two short persistent batch-32 runs retained rocBLAS solution `-1140855025`,
  output size 67,108,864 bytes and SHA-256
  `fe67b80af4671210cd33306d0976c7dbb285dd55203d8eff733866cd7ef4a7a7`;
- the warm request measured 15.711 GPU FW/s and 15.528 effective FW/s, inside
  the previously qualified range.

## MiningView and MiningStatus ownership

The v1.0.13 `MiningView.tsx` consumes work rate, attempts, share counts,
blocks, credited atoms, connection state, height, lifecycle, errors and the
engine/device label. The Rust wallet/coordinator already owns all pool and
session accounting. The AMD contribution supplies only real discovery,
selection, device identity, worker lifecycle errors, batch execution and final
activation output. It deliberately does not recreate pool statistics or add
power, temperature or live-VRAM sensors. The complete field map remains in
`WALLET_INTEGRATION_GUIDE.md`.

## Manual prolonged pool test

Use a currently authenticated pinned endpoint and a public payout address; do
not reuse an old endpoint without verification. First stop any other miner and
select the exact value returned by discovery:

```bash
cd CommonFoundry/Linux/AMD_HIP_Lab
build/bin/cmfd-hip-discovery --list
build/bin/cmfd-hip-discovery --auto-select
```

Then, from `CommonFoundry/Linux/scripts/Mainnet_v1.0.13`, run:

```bash
CMFD_HIP_DEVICE_SELECTOR='uuid:VALUE_FROM_DISCOVERY' \
CMFD_PAYOUT_ADDRESS='64_HEX_PUBLIC_ADDRESS' \
CMFD_POOL_URL='cmfd+tls://NUMERIC_IP:PORT?pin=64_HEX' \
CMFD_WORKER_NAME='amd-hip-long-test' \
./05_MINAGE_AMD_POOL.sh
```

Let it run long enough to cross several jobs/heights and observe several share
responses (30–60 minutes is a useful operator test, not an automated release
test). Stop once with Ctrl+C; do not use `kill -9`. Return the complete newest
`AMD_HIP_Lab/logs/pool/pool-*.log`. The most useful final markers are
`CMFD_HIP_PROTOCOL`, `CMFD_HIP_SERVER_EXIT`, `CMFD_HIP_SIGNAL`,
`CMFD_HIP_ERROR` and the coordinator's `closed stdout` message. A clean stop
should show `action=deferred_to_supervisor`, followed by a real command marker
when a command was active and then `reason=quit` or `reason=stdin_eof`. An EOF
without these diagnostics remains a separate fault requiring host-level
capture.

AMD solo remains unavailable and is outside this work.
