#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
linux_dir="$(cd -- "${script_dir}/../.." && pwd)"
source_lab="${CMFD_AMD_HIP_LAB:-${linux_dir}/AMD_HIP_Lab}"
package_root="$(cd -- "${script_dir}/../../../.." 2>/dev/null && pwd || true)"
source_layout=false
if [[ -x "${source_lab}/runtime/cmfd-hip-runtime" ]]; then
  source_layout=true
  lab_dir="${source_lab}"
  default_model="${linux_dir}/versions/v1.0.13/runtime/commonfoundry-mainnet-runtime-linux-x86_64-v1.0.13/production-v4/MODEL-V2.bank"
  default_runtime_manager="${lab_dir}/runtime/cmfd-hip-runtime"
  default_discovery="${lab_dir}/build/bin/cmfd-hip-discovery"
  default_worker="${lab_dir}/cmfd-v4-hip-worker"
  default_model_verifier="${lab_dir}/tools/verify-model.sh"
  qualification_script="${lab_dir}/benchmarks/run_batch32_qualification.sh"
  default_log_dir="${lab_dir}/logs/diagnostics"
elif [[ -n "${package_root}" && -x "${package_root}/bin/cmfd-hip-runtime" ]]; then
  lab_dir="${package_root}/share/common-foundry/amd-hip"
  default_model=''
  default_runtime_manager="${package_root}/bin/cmfd-hip-runtime"
  default_discovery="${package_root}/bin/cmfd-hip-discovery"
  default_worker="${package_root}/bin/cmfd-v4-hip-worker"
  default_model_verifier="${package_root}/bin/verify-model.sh"
  qualification_script="${lab_dir}/benchmarks/run_batch32_qualification.sh"
  default_log_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/common-foundry/amd-hip/logs/diagnostics"
else
  printf '%s\n' 'DIAGNOSTIC AMD: ECHEC: paquet AMD HIP introuvable; définir CMFD_AMD_HIP_LAB si nécessaire.' >&2
  exit 1
fi
model_bank="${CMFD_MODEL_BANK:-${default_model}}"
expected_model_sha256="${CMFD_MODEL_SHA256:-5f9b213c3bda51b74e4ebabb26607b67385d613aa8d99af915a48ab063e17d4e}"
qualification=false

case "${1:-}" in
  '') ;;
  --quick) ;;
  --qualification) qualification=true ;;
  *) printf 'Usage: %s [--quick|--qualification]\n' "$0" >&2; exit 2 ;;
esac

fail() {
  printf 'DIAGNOSTIC AMD: ECHEC: %s\n' "$*" >&2
  exit 1
}

log_dir="${CMFD_AMD_LOG_DIR:-${default_log_dir}}"
mkdir -p -- "${log_dir}"
chmod 700 -- "${log_dir}"
log_file="${log_dir}/diagnostic-$(date -u '+%Y%m%dT%H%M%SZ').log"
exec > >(tee -a "${log_file}") 2>&1

printf 'COMMON FOUNDRY - DIAGNOSTIC AMD HIP v1.0.13\n'
printf 'Date UTC : %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'Journal : %s\n' "${log_file}"

for command_name in openssl pgrep python3 sha256sum timeout; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "dépendance absente: ${command_name}"
done
[[ -d "${lab_dir}" ]] || fail "ressources AMD introuvables: ${lab_dir}"
[[ -n "${model_bank}" && -r "${model_bank}" ]] || fail 'modèle ProductionV4 introuvable; définir CMFD_MODEL_BANK vers le modèle officiel v1.0.13'
runtime_manager="${CMFD_HIP_RUNTIME_MANAGER:-${default_runtime_manager}}"
discovery_binary="${CMFD_HIP_DISCOVERY:-${default_discovery}}"
worker_binary="${CMFD_REPLAY_WORKER:-${default_worker}}"
model_verifier="${CMFD_MODEL_VERIFIER:-${default_model_verifier}}"
[[ -x "${runtime_manager}" ]] || fail "gestionnaire ROCm introuvable: ${runtime_manager}"
[[ -x "${discovery_binary}" ]] || fail "découverte AMD introuvable: ${discovery_binary}"
[[ -x "${worker_binary}" ]] || fail "worker AMD introuvable: ${worker_binary}"
[[ -x "${model_verifier}" ]] || fail "vérificateur du modèle introuvable: ${model_verifier}"

active_miners="$(pgrep -u "$(id -u)" -af '(^|/)(cmfd-miner|cmfd-v4-hip-replay|xmrig|minerd)( |$)' || true)"
[[ -z "${active_miners}" ]] || fail "un mineur concurrent est actif: ${active_miners}"

"${runtime_manager}" status
prepare_arguments=()
[[ "${CMFD_HIP_AUTHORIZE_DOWNLOAD:-0}" == 1 ]] && prepare_arguments+=(--authorize-download)
"${runtime_manager}" prepare "${prepare_arguments[@]}"
"${runtime_manager}" verify

if [[ "${CMFD_AMD_DEVELOPER_TESTS:-0}" == 1 ]]; then
  [[ "${source_layout}" == true ]] || fail 'tests développeur indisponibles dans le paquet précompilé; utiliser le paquet source'
  "${lab_dir}/build.sh"
  ctest --test-dir "${lab_dir}/build" --output-on-failure
fi
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
    fail 'aucun GPU AMD HIP compatible ne peut être sélectionné'
  fi
  printf '%s\n' "${discovery_json}" >&2
  architecture_prepare_arguments=(--architecture "${missing_architecture}")
  [[ "${CMFD_HIP_AUTHORIZE_DOWNLOAD:-0}" == 1 ]] \
    && architecture_prepare_arguments+=(--authorize-download)
  if ! runtime_json="$("${runtime_manager}" prepare "${architecture_prepare_arguments[@]}")"; then
    printf '%s\n' "${runtime_json}" >&2
    fail "composants ROCm/rocBLAS requis pour ${missing_architecture}"
  fi
  printf '%s\n' "${runtime_json}"
  "${runtime_manager}" verify
  if ! discovery_json="$("${discovery_binary}" "${discovery_arguments[@]}")"; then
    printf '%s\n' "${discovery_json}" >&2
    fail 'la découverte AMD échoue encore après préparation du runtime'
  fi
fi
printf '%s\n' "${discovery_json}"
selected_selector="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["selection"]["worker_selector"])' <<<"${discovery_json}")"
export CMFD_HIP_DEVICE_SELECTOR="${selected_selector}"
unset CMFD_HIP_DEVICE
"${model_verifier}" "${model_bank}" 6442975416 "${expected_model_sha256}"
"${worker_binary}" --self-test

if [[ "${qualification}" == true ]]; then
  [[ -x "${qualification_script}" ]] || fail "script de qualification introuvable: ${qualification_script}"
  CMFD_MODEL_BANK="${model_bank}" \
  CMFD_REPLAY_WORKER="${worker_binary}" \
  CMFD_BENCH_RESULTS="${CMFD_BENCH_RESULTS:-${log_dir}/qualification}" \
    "${qualification_script}"
else
  printf '%s\n' 'QUALIFICATION BATCH 32: non relancée par défaut; utiliser --qualification.'
fi

if [[ -n "${CMFD_POOL_URL:-}" ]]; then
  "${lab_dir}/tools/verify-pool-tls.sh" "${CMFD_POOL_URL}"
  printf '%s\n' 'POOL: endpoint TLS authentifié; lancer 05_MINAGE_AMD_POOL.sh pour la qualification réelle.'
else
  printf '%s\n' 'POOL: qualification réelle non exécutée; CMFD_POOL_URL non fourni.'
fi
printf '%s\n' 'SOLO: NON DISPONIBLE; prouveur complet AMD non qualifié.'
printf '%s\n' 'DIAGNOSTIC AMD: PASS'
