#!/usr/bin/env bash
# One-time WSL2 setup for the Common Foundry AMD HIP miner.
# Added by the Common Foundry project.
#
# 1. Installs AMD's official WSL packages (pinned and checksum-verified):
#    librocdxg (ROCm <-> Windows driver bridge) and AMD SMI for WSL (telemetry).
# 2. Detects the AMD GPU and prepares the private ROCm 7.14 runtime for it.
# 3. Checks that HIP sees the GPU and runs the worker's exact self-test.
#
# Usage: wsl-setup.sh [--yes]     (--yes skips the download confirmation)
set -euo pipefail
umask 022

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "${script_dir}/cmfd-hip-runtime" ]]; then
  manager="${script_dir}/cmfd-hip-runtime"
  discovery="${script_dir}/cmfd-hip-discovery"
  worker="${script_dir}/cmfd-v4-hip-worker"
  telemetry="${script_dir}/../libexec/common-foundry-amd-hip/amd_gpu_telemetry.py"
else
  manager="${script_dir}/../runtime/cmfd-hip-runtime"
  discovery="${script_dir}/../runtime/cmfd-hip-discovery"
  worker="${script_dir}/../cmfd-v4-hip-worker"
  telemetry="${script_dir}/amd_gpu_telemetry.py"
fi

rocdxg_version=1.2.1
rocdxg_url="https://github.com/ROCm/librocdxg/releases/download/v${rocdxg_version}"
packages=(
  "rocdxg-roct_${rocdxg_version}_amd64.deb 184644 7889eef45a1132ed2dde88d8ea1356bf791ec9c05802a18940bc81b970e850e0"
  "rocdxg-amd-smi-lib_${rocdxg_version}_amd64.deb 547942 6ea9872bfd2a8531b930efd307d13e5ca38a7c362d0b66fe2f37addbf95554d2"
)

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

assume_yes=false
case "${1:-}" in
  '') ;;
  --yes|-y) assume_yes=true ;;
  *) printf 'Usage: %s [--yes]\n' "$0" >&2; exit 2 ;;
esac

[[ -e /dev/dxg ]] || fail 'GPU access for WSL2 is missing (/dev/dxg). On Windows run "wsl --update", install the current AMD Software: Adrenalin Edition driver, then "wsl --shutdown" and try again.'
[[ ! -e /dev/kfd ]] || fail 'This looks like native Linux with the amdgpu driver; wsl-setup.sh is only for WSL2.'
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != ubuntu || ( "${VERSION_ID:-}" != 22.04 && "${VERSION_ID:-}" != 24.04 ) ]]; then
    say "Warning: AMD supports ROCm on WSL with Ubuntu 22.04 or 24.04; this is ${PRETTY_NAME:-unknown}."
  fi
fi

say 'Installing base tools (needs sudo)'
sudo apt-get update
sudo apt-get install -y ca-certificates curl openssl python3 procps util-linux coreutils

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
chmod 755 "${work}"
for entry in "${packages[@]}"; do
  read -r file size sha256 <<<"${entry}"
  say "Downloading ${file} (AMD's official librocdxg release)"
  curl --proto '=https' --tlsv1.2 --fail --location --retry 2 --output "${work}/${file}" "${rocdxg_url}/${file}"
  [[ "$(stat -c '%s' -- "${work}/${file}")" == "${size}" ]] || fail "${file}: unexpected size"
  [[ "$(sha256sum -- "${work}/${file}" | awk '{print $1}')" == "${sha256}" ]] || fail "${file}: SHA-256 mismatch"
done

say 'Installing librocdxg and AMD SMI for WSL (needs sudo)'
sudo apt-get install -y "${work}/rocdxg-roct_${rocdxg_version}_amd64.deb" \
  "${work}/rocdxg-amd-smi-lib_${rocdxg_version}_amd64.deb"

say 'Looking for the AMD GPU'
architecture="$(python3 -I "${telemetry}" --architecture)" \
  || fail 'AMD SMI for WSL reports no AMD GPU. Make sure the Windows AMD driver is current and supports WSL, run "wsl --shutdown" on Windows, then try again.'
python3 -I "${telemetry}" --json
printf 'GPU architecture: %s\n' "${architecture}"

if ! "${manager}" resolve >/dev/null 2>&1; then
  if [[ "${assume_yes}" != true ]]; then
    printf '\nROCm 7.14 for %s must be downloaded once from repo.amd.com (about 2.3 GB).\n' "${architecture}"
    read -r -p 'Download it now? [y/N] ' answer
    [[ "${answer,,}" == y* ]] || { say 'Stopped before the download. Run wsl-setup.sh again when ready.'; exit 0; }
  fi
fi
say "Preparing the private ROCm 7.14 runtime for ${architecture}"
"${manager}" prepare --architecture "${architecture}" --authorize-download

say 'Checking that HIP sees the GPU'
selection="$("${discovery}" --auto-select)" || { printf '%s\n' "${selection}" >&2; fail 'HIP discovery could not select the AMD GPU under WSL2.'; }
printf '%s\n' "${selection}"
selector="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["selection"]["worker_selector"])' <<<"${selection}")"

say 'Running the exact GPU self-test'
CMFD_HIP_DEVICE_SELECTOR="${selector}" "${worker}" --self-test \
  || fail 'The GPU self-test failed under WSL2. Please send this output to the Common Foundry team.'

say 'WSL2 setup complete. Start mining with bin/run-miner.sh (see docs/WSL.md).'
