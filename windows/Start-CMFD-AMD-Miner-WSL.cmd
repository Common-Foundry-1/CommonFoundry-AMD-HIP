@echo off
rem Common Foundry AMD HIP miner - start from Windows through WSL2.
rem Added by the Common Foundry project. Run wsl-setup.sh in WSL once first (docs/WSL.md).
rem Edit the settings below, then double-click this file. Paths are inside WSL; ~ is your WSL home.

set "WSL_DISTRO=Ubuntu-24.04"
set "PAYOUT_ADDRESS=PUT_YOUR_64_HEX_PUBLIC_ADDRESS_HERE"
set "POOL_URL=cmfd+tls://IP:PORT?pin=PUT_THE_POOL_PIN_HERE"
set "WORKER_NAME=amd-hip"
set "AMD_MINER_DIR=~/common-foundry-amd-hip-v1.0.15-linux-x86_64"
set "CMFD_MINER=~/cmfd/cmfd-miner"
set "MODEL_BANK=~/cmfd/MODEL-V2.bank"

wsl.exe -d %WSL_DISTRO% -- bash -lc "CMFD_PAYOUT_ADDRESS='%PAYOUT_ADDRESS%' CMFD_POOL_URL='%POOL_URL%' CMFD_WORKER_NAME='%WORKER_NAME%' CMFD_MINER_BINARY=%CMFD_MINER% CMFD_MODEL_BANK=%MODEL_BANK% exec %AMD_MINER_DIR%/bin/run-miner.sh"
pause
