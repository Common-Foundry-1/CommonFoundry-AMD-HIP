# Running on Windows with WSL2 (experimental)

Added by the Common Foundry project.

> **Status:** the WSL2 path has not yet been tested on a real AMD GPU. The
> scripts are tested without a GPU. If you try it, please send the output of
> `wsl-setup.sh` and the first minutes of mining to the Common Foundry team.

The miner runs inside an Ubuntu WSL2 distribution and reaches the GPU through
AMD's Windows driver (`/dev/dxg`), using AMD's official WSL packages:

- **librocdxg** connects ROCm to the Windows AMD driver.
- **AMD SMI for WSL** provides power, temperature, fan, clock, load and VRAM
  readings for the mining screen.

## Requirements

- Windows 11 with WSL2 (`wsl --update`).
- A Radeon GPU that AMD supports on WSL2: RX 9000 series, RX 7900 / 7800 /
  7700 / 7600 series, or Radeon PRO W7000 series. Only the RX 7900 XTX
  (`gfx1100`) is qualified for this miner; other cards run the same exact
  self-test before mining.
- The current **AMD Software: Adrenalin Edition** driver on Windows.
- Ubuntu 22.04 or 24.04 in WSL2: `wsl --install -d Ubuntu-24.04`.
- About 8 GB free VRAM (Windows keeps some VRAM; a 24 GB card shows ~21 GB in
  WSL) and about 10 GB of disk inside WSL.

## Setup (once)

In Ubuntu (WSL):

```bash
curl -LO https://github.com/Common-Foundry-1/CommonFoundry-AMD-HIP/releases/download/<tag>/<package>.tar.gz
tar -xzf <package>.tar.gz
<package>/bin/wsl-setup.sh
```

`wsl-setup.sh` installs AMD's two WSL packages (checksum-verified, needs
`sudo`), finds the GPU, downloads ROCm 7.14 for it from `repo.amd.com`
(about 2.3 GB, asks first), checks that HIP sees the GPU and runs the exact
GPU self-test.

You also need the official Common Foundry `v1.0.13` Linux miner
(`commonfoundry-mainnet-miner-linux-x86_64-v1.0.13.tar.gz` from the
Common Foundry release) and its `MODEL-V2.bank`. Keep both inside the WSL
filesystem (for example `~/cmfd`), not under `/mnt/c`, so the 6.4 GB model
loads quickly.

## Start mining

```bash
CMFD_MINER_BINARY=~/cmfd/cmfd-miner \
CMFD_MODEL_BANK=~/cmfd/MODEL-V2.bank \
CMFD_PAYOUT_ADDRESS=<64-hex-public-address> \
CMFD_POOL_URL='cmfd+tls://IP:PORT?pin=<64-hex>' \
<package>/bin/run-miner.sh
```

From Windows, edit the settings at the top of
`Start-CMFD-AMD-Miner-WSL.cmd` (a release asset) and double-click it.

## Mining screen

`run-miner.sh` opens a live screen:

- pool, connection status, block height, worker and payout address;
- hashrate now and session average, plus the GPU's own per-batch rate;
- accepted / rejected / stale shares, acceptance rate, shares per hour and
  time since the last accepted share;
- blocks found and pool credit in CMFD;
- power draw and limit, efficiency (FW/kWh);
- edge, hotspot and memory temperature, fan, GPU load, core and memory
  clocks, VRAM used;
- recent events and the log file path.

Press **Ctrl+C** to stop. Everything is also written to a log under
`~/.local/state/common-foundry/amd-hip/logs/miner/`. Set `CMFD_SCREEN=0`
for plain scrolling output. The same screen is used on native Linux, where
readings come from the amdgpu driver.

## If something fails

Please report:

1. the full output of `wsl-setup.sh`;
2. `<package>/bin/cmfd-hip-runtime status`;
3. the miner log.

Most likely WSL-specific problems, so we know what to look for:

- **Pinned host memory** (`hipHostMalloc`) or **HIP Graphs** failing under
  WSL; the worker reports `CMFD_HIP_ERROR` with the failing call.
- **Not enough free VRAM** because Windows keeps part of it.
- AMD SMI showing `N/A` for some sensors on older drivers; mining still works.
