#!/usr/bin/env bash
set -euo pipefail

lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"${lab_dir}/build.sh"
ctest --test-dir "${lab_dir}/build" --output-on-failure
"${lab_dir}/build/bin/cmfd-hip-discovery" --list
if [[ -n "${CMFD_HIP_DEVICE_SELECTOR:-}" ]]; then
  "${lab_dir}/build/bin/cmfd-hip-discovery" --select "${CMFD_HIP_DEVICE_SELECTOR}"
  device_arguments=(--device-selector "${CMFD_HIP_DEVICE_SELECTOR}")
else
  "${lab_dir}/build/bin/cmfd-hip-discovery" --auto-select
  device_arguments=()
fi
"${lab_dir}/cmfd-v4-hip-worker" "${device_arguments[@]}" --self-test
