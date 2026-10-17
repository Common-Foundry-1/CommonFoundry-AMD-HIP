#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cmake_arguments=(-DCMAKE_BUILD_TYPE=Release)
if [[ -n "${CMFD_HIP_ARCHITECTURES:-}" ]]; then
  cmake_arguments+=("-DCMFD_HIP_ARCHITECTURES=${CMFD_HIP_ARCHITECTURES}")
fi
if [[ -n "${CMFD_HIP_TESTED_ARCHITECTURES:-}" ]]; then
  cmake_arguments+=("-DCMFD_HIP_TESTED_ARCHITECTURES=${CMFD_HIP_TESTED_ARCHITECTURES}")
fi
cmake -S "$SCRIPT_DIR" -B "$SCRIPT_DIR/build" "${cmake_arguments[@]}"
cmake --build "$SCRIPT_DIR/build" --parallel
