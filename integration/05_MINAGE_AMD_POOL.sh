#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
linux_dir="$(cd -- "${script_dir}/../.." && pwd)"
source_lab="${CMFD_AMD_HIP_LAB:-${linux_dir}/AMD_HIP_Lab}"
package_root="$(cd -- "${script_dir}/../../../.." 2>/dev/null && pwd || true)"
if [[ -x "${source_lab}/run-miner.sh" ]]; then
  launcher="${source_lab}/run-miner.sh"
  default_log_dir="${source_lab}/logs/pool"
elif [[ -n "${package_root}" && -x "${package_root}/bin/run-miner.sh" ]]; then
  launcher="${package_root}/bin/run-miner.sh"
  default_log_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/common-foundry/amd-hip/logs/pool"
else
  printf '%s\n' 'ERREUR : paquet AMD HIP introuvable; définir CMFD_AMD_HIP_LAB si nécessaire.' >&2
  exit 1
fi
payout_address="${CMFD_PAYOUT_ADDRESS:-${1:-}}"
pool_url="${CMFD_POOL_URL:-${2:-}}"
worker_name="${CMFD_WORKER_NAME:-amd-hip}"

if [[ ! "${payout_address}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
  printf '%s\n' 'ERREUR : fournir une adresse publique CMFD de 64 caractères hexadécimaux.' >&2
  printf '%s\n' 'Usage : CMFD_PAYOUT_ADDRESS=<adresse> CMFD_POOL_URL=<url-tls-épinglee> ./05_MINAGE_AMD_POOL.sh' >&2
  exit 2
fi
if [[ -z "${pool_url}" ]]; then
  printf '%s\n' 'ERREUR : CMFD_POOL_URL est obligatoire; aucune URL historique ou par défaut ne sera utilisée.' >&2
  exit 2
fi
log_dir="${CMFD_AMD_LOG_DIR:-${default_log_dir}}"
mkdir -p -- "${log_dir}"
chmod 700 -- "${log_dir}"
log_file="${log_dir}/pool-$(date -u '+%Y%m%dT%H%M%SZ').log"
exec > >(tee -a "${log_file}") 2>&1

printf 'COMMON FOUNDRY - MINAGE AMD HIP POOL v1.0.13\n'
printf 'Journal : %s\n' "${log_file}"
printf 'Worker : %s\n' "${worker_name}"
printf 'Adresse publique : %s\n' "${payout_address,,}"
printf 'Le certificat TLS, le modèle officiel, le matériel et le worker seront vérifiés avant connexion.\n'

export CMFD_PAYOUT_ADDRESS="${payout_address,,}"
export CMFD_POOL_URL="${pool_url}"
export CMFD_WORKER_NAME="${worker_name}"
exec "${launcher}"
