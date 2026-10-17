#!/usr/bin/env bash
set -euo pipefail
umask 077

lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "${lab_dir}/cmfd-hip-runtime" && -x "${lab_dir}/cmfd-hip-discovery" ]]; then
  prefix_dir="$(cd -- "${lab_dir}/.." && pwd)"
  default_package=''
  default_model=''
  default_worker="${lab_dir}/cmfd-v4-hip-worker"
  default_discovery="${lab_dir}/cmfd-hip-discovery"
  default_manager="${lab_dir}/cmfd-hip-runtime"
  default_tls_verifier="${lab_dir}/verify-pool-tls.sh"
  default_model_verifier="${lab_dir}/verify-model.sh"
  compatibility_tools="${prefix_dir}/libexec/common-foundry-amd-hip"
  default_scratch="${XDG_STATE_HOME:-${HOME}/.local/state}/common-foundry/amd-hip/scratch/mainnet-v1.0.13"
  default_screen_logs="${XDG_STATE_HOME:-${HOME}/.local/state}/common-foundry/amd-hip/logs/miner"
else
  default_package="${lab_dir}/../versions/v1.0.13/commonfoundry-mainnet-miner-linux-x86_64-v1.0.13"
  default_model="${lab_dir}/../versions/v1.0.13/runtime/commonfoundry-mainnet-runtime-linux-x86_64-v1.0.13/production-v4/MODEL-V2.bank"
  default_worker="${lab_dir}/cmfd-v4-hip-worker"
  default_discovery="${lab_dir}/build/bin/cmfd-hip-discovery"
  default_manager="${lab_dir}/runtime/cmfd-hip-runtime"
  default_tls_verifier="${lab_dir}/tools/verify-pool-tls.sh"
  default_model_verifier="${lab_dir}/tools/verify-model.sh"
  compatibility_tools="${lab_dir}/tools"
  default_scratch="${lab_dir}/scratch/mainnet-v1.0.13"
  default_screen_logs="${lab_dir}/logs/miner"
fi
package_dir="${CMFD_MINER_PACKAGE:-${default_package}}"
miner_binary="${CMFD_MINER_BINARY:-${package_dir:+${package_dir}/cmfd-miner}}"
model_bank="${CMFD_MODEL_BANK:-${default_model}}"
worker_binary="${CMFD_REPLAY_WORKER:-${default_worker}}"
discovery_binary="${CMFD_HIP_DISCOVERY:-${default_discovery}}"
runtime_manager="${CMFD_HIP_RUNTIME_MANAGER:-${default_manager}}"
scratch_dir="${CMFD_SCRATCH_DIR:-${default_scratch}}"
pool_url="${CMFD_POOL_URL:-${2:-}}"
worker_name="${CMFD_WORKER_NAME:-amd-hip}"
payout_address="${CMFD_PAYOUT_ADDRESS:-${1:-}}"
expected_model_sha256="${CMFD_MODEL_SHA256:-5f9b213c3bda51b74e4ebabb26607b67385d613aa8d99af915a48ab063e17d4e}"
tls_verifier="${CMFD_TLS_VERIFIER:-${default_tls_verifier}}"
model_verifier="${CMFD_MODEL_VERIFIER:-${default_model_verifier}}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ ! "${payout_address}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
  printf '%s\n' 'ERROR: a 64-hex public payout address is required.' >&2
  printf '%s\n' 'Use: CMFD_PAYOUT_ADDRESS=<address> CMFD_POOL_URL=<pinned-url> ./run-miner.sh' >&2
  exit 2
fi
if [[ -z "${pool_url}" ]]; then
  printf '%s\n' 'ERROR: CMFD_POOL_URL is required; no endpoint is embedded or assumed.' >&2
  printf '%s\n' 'Obtain the complete current URL from the pool operator through an authenticated channel.' >&2
  exit 2
fi
if [[ ! "${worker_name}" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; then
  printf '%s\n' 'ERROR: CMFD_WORKER_NAME must contain 1-32 safe ASCII characters.' >&2
  exit 2
fi

for command_name in openssl python3 sha256sum timeout; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "required command not found: ${command_name}"
done
[[ -n "${miner_binary}" && -x "${miner_binary}" ]] || fail 'official cmfd-miner is missing; set CMFD_MINER_BINARY or CMFD_MINER_PACKAGE'
[[ -x "${worker_binary}" ]] || fail "HIP replay worker is missing or not executable: ${worker_binary}"
[[ -x "${discovery_binary}" ]] || fail "HIP discovery helper is missing or not executable: ${discovery_binary}"
[[ -x "${runtime_manager}" ]] || fail "HIP runtime manager is missing or not executable: ${runtime_manager}"
[[ -x "${tls_verifier}" ]] || fail "TLS verifier is missing or not executable: ${tls_verifier}"
[[ -x "${model_verifier}" ]] || fail "model verifier is missing or not executable: ${model_verifier}"
[[ -n "${model_bank}" && -r "${model_bank}" ]] || fail 'ProductionV4 model bank is missing; set CMFD_MODEL_BANK to the official v1.0.13 model'
[[ -x "${compatibility_tools}/nvidia-smi" ]] || fail "coordinator compatibility probe is missing: ${compatibility_tools}/nvidia-smi"

if pgrep -u "$(id -u)" -x cmfd-miner >/dev/null 2>&1; then
  fail 'another cmfd-miner process is already running for this user'
fi

prepare_arguments=()
if [[ "${CMFD_HIP_AUTHORIZE_DOWNLOAD:-0}" == 1 ]]; then
  prepare_arguments+=(--authorize-download)
fi
if ! runtime_json="$("${runtime_manager}" prepare "${prepare_arguments[@]}")"; then
  printf '%s\n' "${runtime_json}" >&2
  fail 'ROCm/HIP runtime preparation failed; explicit download or system authorization may be required'
fi
printf '%s\n' "${runtime_json}"
if [[ -n "${CMFD_HIP_DEVICE_SELECTOR:-}" ]]; then
  discovery_arguments=(--select "${CMFD_HIP_DEVICE_SELECTOR}")
  requested_selector="${CMFD_HIP_DEVICE_SELECTOR}"
elif [[ -n "${CMFD_HIP_DEVICE:-}" ]]; then
  discovery_arguments=(--select "hip:${CMFD_HIP_DEVICE}")
  requested_selector="hip:${CMFD_HIP_DEVICE}"
else
  discovery_arguments=(--auto-select)
  requested_selector=''
fi
if ! discovery_json="$("${discovery_binary}" "${discovery_arguments[@]}")"; then
  missing_architecture="$(REQUESTED_SELECTOR="${requested_selector}" python3 -c '
import json, os, sys
try:
    document = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
devices = [device for device in document.get("devices", [])
           if device.get("qualification") == "rocblas_architecture_unavailable"]
selector = os.environ.get("REQUESTED_SELECTOR", "").lower()
if selector:
    devices = [device for device in devices
               if str(device.get("worker_selector", "")).lower() == selector]
else:
    dedicated = [device for device in devices if device.get("integrated") is False]
    if len(dedicated) == 1:
        devices = dedicated
if len(devices) == 1:
    print(devices[0].get("architecture", ""))
' <<<"${discovery_json}" 2>/dev/null || true)"
  if [[ -z "${missing_architecture}" ]]; then
    printf '%s\n' "${discovery_json}" >&2
    fail 'no compatible AMD HIP device could be selected'
  fi
  printf '%s\n' "${discovery_json}" >&2
  architecture_prepare_arguments=(--architecture "${missing_architecture}")
  [[ "${CMFD_HIP_AUTHORIZE_DOWNLOAD:-0}" == 1 ]] \
    && architecture_prepare_arguments+=(--authorize-download)
  if ! runtime_json="$("${runtime_manager}" prepare "${architecture_prepare_arguments[@]}")"; then
    printf '%s\n' "${runtime_json}" >&2
    fail "matching ROCm/rocBLAS components are required for ${missing_architecture}"
  fi
  printf '%s\n' "${runtime_json}"
  if ! discovery_json="$("${discovery_binary}" "${discovery_arguments[@]}")"; then
    printf '%s\n' "${discovery_json}" >&2
    fail 'AMD HIP discovery still fails after runtime preparation'
  fi
fi
printf '%s\n' "${discovery_json}"
selected_selector="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["selection"]["worker_selector"])' <<<"${discovery_json}")"
[[ -n "${selected_selector}" ]] || fail 'HIP discovery returned no worker selector'
export CMFD_HIP_DEVICE_SELECTOR="${selected_selector}"
unset CMFD_HIP_DEVICE
# The mining screen and telemetry follow the GPU the worker selected.
mapfile -t selected_details < <(python3 -c '
import json, sys
document = json.load(sys.stdin)
selector = document["selection"]["worker_selector"]
device = next((d for d in document.get("devices", []) if d.get("worker_selector") == selector), {})
for key in ("pci_bus_id", "name", "architecture"):
    print(" ".join(str(device.get(key) or "").split()))
' <<<"${discovery_json}" 2>/dev/null || true)
export CMFD_HIP_TELEMETRY_PCI="${selected_details[0]:-}"
export CMFD_HIP_GPU_NAME="${selected_details[1]:-}"
export CMFD_HIP_GPU_ARCH="${selected_details[2]:-}"
"${model_verifier}" "${model_bank}" 6442975416 "${expected_model_sha256}"
"${tls_verifier}" "${pool_url}"
"${worker_binary}" --self-test

mkdir -p -- "${scratch_dir}"
chmod 700 -- "${scratch_dir}"
miner_binary="$(realpath -e -- "${miner_binary}")"
worker_binary="$(realpath -e -- "${worker_binary}")"
model_bank="$(realpath -e -- "${model_bank}")"
scratch_dir="$(realpath -e -- "${scratch_dir}")"

# The v1.0.13 coordinator insists on NVIDIA discovery before it starts an
# external worker.  This project-local PATH entry supplies only that narrow
# compatibility probe; the selected worker remains the native HIP executable.
export PATH="${compatibility_tools}:${PATH}"

miner_command=("${miner_binary}" pool \
  --pool "${pool_url}" \
  --miner "${payout_address,,}" \
  --worker "${worker_name}" \
  --production-v4-bank "${model_bank}" \
  --production-v4-replay-worker "${worker_binary}" \
  --production-v4-scratch "${scratch_dir}" \
  --stats-seconds "${CMFD_STATS_SECONDS:-5}")

# The mining screen runs the coordinator, keeps a log and caches AMD telemetry
# for the compatibility probe.  CMFD_SCREEN=0 keeps plain output.
screen="${compatibility_tools}/cmfd-amd-screen"
if [[ -r "${screen}" ]]; then
  export CMFD_HIP_TELEMETRY_CACHE="${scratch_dir}/telemetry.json"
  screen_logs="${CMFD_SCREEN_LOG_DIR:-${default_screen_logs}}"
  mkdir -p -- "${screen_logs}"
  chmod 700 -- "${screen_logs}"
  exec python3 -I "${screen}" --log "${screen_logs}/miner-$(date -u '+%Y%m%dT%H%M%SZ').log" \
    -- "${miner_command[@]}"
fi
exec "${miner_command[@]}"
