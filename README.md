# Common Foundry AMD HIP Miner

Native AMD (ROCm/HIP) replay worker for Common Foundry Mainnet `v1.0.13`
pool mining. Open source under the MIT license. **No dev fee.**

Written by **Qcvibes1**, commissioned by the Common Foundry project.

## What it is

- A HIP/rocBLAS replacement for the CUDA replay/search worker used by the
  official `v1.0.13` `cmfd-miner` pool coordinator.
- The official coordinator still handles the pool connection, shares, target
  checks and your payout address. This worker only computes batches; it has no
  network code.
- **Pool only.** Solo mining is not supported (`06_MINAGE_AMD_SOLO.sh` refuses
  to start).
- **Qualified on RX 7900 XTX (`gfx1100`)**, about 15.5 FW/s. The binary also
  contains code for `gfx906` through `gfx1201`, but other cards are untested.
  Every start runs a short exact self-test before mining.
- Linux x86-64 only. Needs ~7.8 GB free VRAM, the AMD `amdgpu` driver, and
  ROCm 7.14 user space (the runtime manager can fetch it from AMD's official
  repo with your consent).

## Download

Get `common-foundry-amd-hip-v1.0.13-linux-x86_64.tar.gz` from
[Releases](../../releases). You also need the official `v1.0.13` `cmfd-miner`
and `MODEL-V2.bank` from the Common Foundry release.

```bash
CMFD_MINER_BINARY=/path/to/cmfd-miner \
CMFD_MODEL_BANK=/path/to/MODEL-V2.bank \
CMFD_PAYOUT_ADDRESS=<64-hex-public-address> \
CMFD_POOL_URL='cmfd+tls://IP:PORT?pin=<64-hex>' \
CMFD_HIP_AUTHORIZE_DOWNLOAD=1 \
./bin/run-miner.sh
```

`CMFD_HIP_AUTHORIZE_DOWNLOAD=1` is only needed on first start if ROCm 7.14 is
not already installed. See [docs/LINUX_DEPLOYMENT.md](docs/LINUX_DEPLOYMENT.md).

## Windows (WSL2, experimental)

Runs inside Ubuntu on WSL2 using AMD's official WSL driver bridge. Run
`bin/wsl-setup.sh` once, then start as above or with
`Start-CMFD-AMD-Miner-WSL.cmd` from Windows. Not yet tested on a real AMD GPU
under WSL2; see [docs/WSL.md](docs/WSL.md).

## Mining screen

`run-miner.sh` shows a live screen with hashrate (now, average and per GPU
batch), accepted/rejected/stale shares, blocks, pool credit, power draw,
efficiency, temperatures, fan, load, clocks and VRAM. Ctrl+C stops mining.
A full log is kept; `CMFD_SCREEN=0` gives plain output. Readings come from
the amdgpu driver on Linux and AMD SMI on WSL2, and also replace the zeros the
coordinator used to print for power and temperature.

## Build from source

Requires ROCm/HIP 7.14, rocBLAS, CMake 3.21+ and a C++20 compiler.

```bash
./build.sh
./test.sh
```

## Documentation

The author's documentation is in [`docs/`](docs/), unchanged:

- [README](docs/README.md) – worker overview, build, benchmark, pool launch
- [FOUNDER_HANDOFF](docs/FOUNDER_HANDOFF.md) – contribution contents and results
- [LINUX_DEPLOYMENT](docs/LINUX_DEPLOYMENT.md) – first-run runtime install
- [DISCOVERY_API](docs/DISCOVERY_API.md) – device discovery JSON contract
- [WALLET_INTEGRATION_GUIDE](docs/WALLET_INTEGRATION_GUIDE.md)
- [AMD_HIP_INTEGRATION_REPORT](docs/AMD_HIP_INTEGRATION_REPORT.md)
- [RELIABILITY_FINALIZATION](docs/RELIABILITY_FINALIZATION.md)
- [THIRD_PARTY_NOTICES](docs/THIRD_PARTY_NOTICES.md)

This repository was assembled from the `v1.0.13` release package (author
source commit `0287d7d`). A few files the docs mention were not in that
package: `package-linux.sh`, `benchmarks/run_batch_sweep.sh`,
`benchmarks/results/`, `benchmarks/qualification/2026-10-12-QUALIFICATION.md`
and `analysis/`. The 2026-10-14 and 2026-10-15 qualification reports are in
`docs/`.

## Credits

AMD HIP worker, discovery, runtime manager, tests and documentation by
**Qcvibes1**. Thank you!

WSL2 support, the mining screen and AMD telemetry were added by the Common
Foundry project (`tools/amd_gpu_telemetry.py`, `tools/cmfd-amd-screen`,
`tools/wsl-setup.sh`, `docs/WSL.md`, `windows/`).
