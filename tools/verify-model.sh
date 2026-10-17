#!/usr/bin/env bash
set -euo pipefail
umask 077

if (($# != 3)); then
  printf 'usage: %s MODEL EXPECTED_SIZE EXPECTED_SHA256\n' "$0" >&2
  exit 2
fi
model=$1
expected_size=$2
expected_sha=${3,,}
[[ "${expected_size}" =~ ^[0-9]+$ && "${expected_sha}" =~ ^[0-9a-f]{64}$ ]] || {
  printf '%s\n' 'CMFD_MODEL_INTEGRITY_ERROR invalid expected metadata' >&2
  exit 2
}
[[ -r "${model}" ]] || {
  printf 'CMFD_MODEL_INTEGRITY_ERROR unreadable model: %s\n' "${model}" >&2
  exit 1
}

actual_size="$(stat -Lc '%s' -- "${model}")"
[[ "${actual_size}" == "${expected_size}" ]] || {
  printf 'CMFD_MODEL_INTEGRITY_ERROR size expected=%s actual=%s\n' "${expected_size}" "${actual_size}" >&2
  exit 1
}

if [[ -n "${CMFD_MODEL_CACHE_DIR:-}" ]]; then
  cache_dir=${CMFD_MODEL_CACHE_DIR}
elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
  cache_dir="${XDG_CACHE_HOME}/common-foundry/amd-hip"
else
  cache_dir="${HOME}/.cache/common-foundry/amd-hip"
fi
mkdir -p -- "${cache_dir}"
chmod 700 -- "${cache_dir}"
cache_key="$(printf '%s' "$(realpath -e -- "${model}")" | sha256sum | awk '{print $1}')"
cache_file="${cache_dir}/model-${cache_key}.manifest"
identity="$(stat -Lc '%d:%i:%s:%y:%z' -- "${model}")"

cached_identity=''
cached_sha=''
if [[ -r "${cache_file}" ]]; then
  while IFS='=' read -r key value; do
    case "${key}" in
      identity) cached_identity=${value} ;;
      sha256) cached_sha=${value} ;;
    esac
  done <"${cache_file}"
fi
if [[ "${cached_identity}" == "${identity}" && "${cached_sha}" == "${expected_sha}" ]]; then
  printf 'CMFD_MODEL_INTEGRITY_OK source=cache sha256=%s\n' "${expected_sha}"
  exit 0
fi

actual_sha="$(sha256sum -- "${model}" | awk '{print tolower($1)}')"
[[ "${actual_sha}" == "${expected_sha}" ]] || {
  printf 'CMFD_MODEL_INTEGRITY_ERROR sha256 expected=%s actual=%s\n' "${expected_sha}" "${actual_sha}" >&2
  exit 1
}
temporary="${cache_file}.tmp.$$"
{
  printf 'schema=common-foundry.model-integrity-v1\n'
  printf 'identity=%s\n' "${identity}"
  printf 'sha256=%s\n' "${actual_sha}"
} >"${temporary}"
chmod 600 -- "${temporary}"
mv -f -- "${temporary}" "${cache_file}"
printf 'CMFD_MODEL_INTEGRITY_OK source=sha256 sha256=%s\n' "${actual_sha}"
