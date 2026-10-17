#!/usr/bin/env bash
set -euo pipefail
umask 077

lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
linux_dir="$(cd -- "${lab_dir}/.." && pwd)"
worker="${CMFD_REPLAY_WORKER:-${lab_dir}/cmfd-v4-hip-worker}"
model="${CMFD_MODEL_BANK:-${linux_dir}/versions/v1.0.13/runtime/commonfoundry-mainnet-runtime-linux-x86_64-v1.0.13/production-v4/MODEL-V2.bank}"
package="${CMFD_MINER_PACKAGE:-${linux_dir}/versions/v1.0.13/commonfoundry-mainnet-miner-linux-x86_64-v1.0.13}"
miner="${CMFD_MINER_BINARY:-${package}/cmfd-miner}"
fixed_record="${CMFD_FIXED_RECORD:-${package}/FORGEMATRIX-V4-FIXED-ARTIFACT-RECORD-V1.json}"
template="${CMFD_BATCH32_TEMPLATE:-${lab_dir}/fixtures/mainnet-template-nonce0.bin}"
coefficients="${CMFD_BATCH32_COEFFICIENTS:-${lab_dir}/fixtures/mainnet-template-nonce0-count32.coefficients.bin}"
results="${CMFD_BENCH_RESULTS:-${lab_dir}/benchmarks/results}"
runs="${CMFD_BATCH32_RUNS:-4}"
solution="${CMFD_BATCH32_SOLUTION:--1140855025}"
expected_hash="${CMFD_BATCH32_EXPECTED_SHA256:-fe67b80af4671210cd33306d0976c7dbb285dd55203d8eff733866cd7ef4a7a7}"

fail() {
  printf 'CMFD_BATCH32_QUALIFICATION_ERROR %s\n' "$*" >&2
  exit 1
}

[[ "${runs}" =~ ^[0-9]+$ ]] && ((runs >= 2 && runs <= 20)) || fail 'CMFD_BATCH32_RUNS must be from 2 through 20'
[[ -x "${worker}" ]] || fail "worker is missing or not executable: ${worker}"

device_arguments=()
if [[ -n "${CMFD_HIP_DEVICE_SELECTOR:-}" ]]; then
  device_arguments=(--device-selector "${CMFD_HIP_DEVICE_SELECTOR}")
elif [[ -n "${CMFD_HIP_DEVICE:-}" ]]; then
  device_arguments=(--device "${CMFD_HIP_DEVICE}")
fi
[[ -x "${miner}" ]] || fail "official inspector is missing or not executable: ${miner}"
for required in "${model}" "${fixed_record}" "${template}" "${coefficients}"; do
  [[ -r "${required}" ]] || fail "required input is missing or unreadable: ${required}"
done

mkdir -p -- "${results}"
worker="$(realpath -e -- "${worker}")"
model="$(realpath -e -- "${model}")"
miner="$(realpath -e -- "${miner}")"
fixed_record="$(realpath -e -- "${fixed_record}")"
template="$(realpath -e -- "${template}")"
coefficients="$(realpath -e -- "${coefficients}")"
results="$(realpath -e -- "${results}")"

"${worker}" "${device_arguments[@]}" --self-test

{
  for ((run = 1; run <= runs; ++run)); do
    printf 'RUNBATCH\t32\t%s\t%s\n' "${coefficients}" "${results}/qualification-batch32-run${run}"
  done
  printf 'QUIT\n'
} | "${worker}" "${device_arguments[@]}" --solution "${solution}" --server "${model}"

for ((run = 1; run <= runs; ++run)); do
  output="${results}/qualification-batch32-run${run}-final-activation.bin"
  actual_hash="$(sha256sum -- "${output}" | awk '{print tolower($1)}')"
  [[ "${actual_hash}" == "${expected_hash}" ]] || fail "run ${run} output hash mismatch: ${actual_hash}"
  printf 'CMFD_BATCH32_OUTPUT run=%d sha256=%s bytes=%s\n' \
    "${run}" "${actual_hash}" "$(stat -c '%s' -- "${output}")"
done

last_output="${results}/qualification-batch32-run${runs}-final-activation.bin"
"${miner}" inspect-v4-search-batch \
  --template "${template}" \
  --start-nonce 0 \
  --count 32 \
  --final-activations "${last_output}" \
  --fixed-record "${fixed_record}" \
  --winner-final-output "${results}/qualification-batch32-winner.bin"

printf 'CMFD_BATCH32_QUALIFICATION_PASS runs=%s solution=%s sha256=%s\n' \
  "${runs}" "${solution}" "${expected_hash}"
