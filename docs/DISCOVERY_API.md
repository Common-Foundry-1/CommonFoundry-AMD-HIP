# AMD HIP discovery API

`cmfd-hip-discovery` is the machine-readable hardware boundary for the
Common Foundry AMD backend. It dynamically loads HIP, enumerates every HIP GPU
and keeps five different facts separate:

1. detected by HIP;
2. architecture embedded in this worker;
3. packaged rocBLAS and ProductionV4 static requirements available;
4. startup cryptographic self-test passed (worker runtime log);
5. architecture physically qualified by this project.

Detection or compilation alone is never presented as physical validation.

## Commands and integrated policy

```bash
build/bin/cmfd-hip-discovery --list
build/bin/cmfd-hip-discovery --auto-select
build/bin/cmfd-hip-discovery --select 'uuid:...'
build/bin/cmfd-hip-discovery --select 'pci:0000:0a:00.0'
build/bin/cmfd-hip-discovery --select 'hip:0'

# Safe default is 0. Opt in to integrated GPUs without rebuilding:
CMFD_HIP_ALLOW_INTEGRATED=1 build/bin/cmfd-hip-discovery --list
```

`CMFD_HIP_ALLOW_INTEGRATED` accepts only `0` or `1`. The HIP
`integrated` property is used directly; model names are never guessed. If
HIP cannot determine the type, the safe default rejects it and opt-in permits
an explicit attempt. Every invocation writes exactly one JSON object and a
newline to stdout. The caller must check both `status` and the exit code.

## Schema version 1

The existing schema version is retained because the additions are backward
compatible. Existing fields keep their type and meaning; new consumers should
prefer the explicit compatibility fields:

```json
{
  "schema": "common-foundry.amd-hip.discovery",
  "schema_version": 1,
  "backend": "amd-hip",
  "status": "ok",
  "qualified_architectures": ["gfx1036", "gfx1100"],
  "compiled_architectures": ["gfx1036", "gfx1100"],
  "rocblas_architectures": ["gfx1100"],
  "physically_tested_architectures": ["gfx1036", "gfx1100"],
  "runtime": {
    "available": true,
    "root": "/opt/rocm",
    "source": "environment",
    "version": "7.14.60850",
    "hip_library": "/opt/rocm/lib/libamdhip64.so",
    "rocblas_library": "/opt/rocm/lib/librocblas.so",
    "rocblas_library_directory": "/opt/rocm/lib/rocblas/library",
    "error": null
  },
  "policy": {
    "allow_integrated": false,
    "minimum_production_v4_memory_bytes": 7767843456,
    "estimated_allocation_bytes": 6962537088,
    "memory_safety_margin_bytes": 805306368
  },
  "devices": [],
  "selection": null,
  "error": null
}
```

`qualified_architectures` remains as a compatibility alias for
`physically_tested_architectures`. It does not enumerate all code objects.
`compiled_architectures` comes from the actual CMake build.
`rocblas_architectures` is detected from the rocBLAS payload in the runtime
selected for this process. `runtime` identifies that root, its reported
version, how it was selected and whether both HIP and rocBLAS are coherent.
This is evaluated at launch; it is not a configure-time snapshot. The worker
requires the ROCm 7.14 ABI family and rejects a different or unknown family
before device selection.

Each device contains:

| Field | Meaning |
| --- | --- |
| `hip_index` | HIP ordinal in this process. |
| `name` | Name reported by HIP. |
| `architecture` / `architecture_detail` | Normalized and complete `gcnArchName`. |
| `vram_bytes` | `totalGlobalMem`; shared aperture for an iGPU, not necessarily dedicated VRAM. |
| `available_memory_bytes` | Current `hipMemGetInfo` free bytes, or `null`. |
| `integrated` / `device_type` | HIP integrated flag and `integrated`, `discrete` or `unknown`. |
| `max_threads_per_block`, `warp_size`, `compute_units` | HIP capabilities used for support decisions or labels. |
| `uuid`, `pci_bus_id`, `stable_id` | Hardware/topology identity when available. |
| `worker_selector` | Exact selector accepted by the worker. |
| `selector_stability` | `hardware`, `topology` or `session`. |
| `architecture_compiled` | This binary embeds the device architecture. |
| `rocblas_architecture_available` | Packaged rocBLAS has matching code objects. |
| `total_memory_sufficient` | HIP reports at least 7,767,843,456 bytes total: model allocation + workspace allocation + 768 MiB safety margin. |
| `available_memory_sufficient` | Current free HIP memory reaches the same calculated floor, or is unavailable to query. |
| `workgroup_supported` | Device permits the preserved 512-thread kernels. |
| `integrated_allowed` | Current policy permits this device type. |
| `compatible` | All static/runtime-package preconditions above pass. |
| `qualified` | Backward-compatible alias of `compatible`. |
| `physically_tested` | This exact architecture has project hardware evidence. |
| `runtime_validation_required` | Exact worker self-test/hardware qualification is still required. |
| `qualification` | Stable reason such as `qualified`, `runtime_validation_required`, `rocblas_architecture_unavailable` or `insufficient_total_memory`. |

`uuid:` is preferred. `pci:` can change if hardware moves and `hip:` is
session-scoped. Names and architectures are not selectors because they can be
duplicated.

## Selection rules

- No compatible device: `no_qualified_device`.
- Exactly one compatible device: automatic selection succeeds.
- Several compatible dedicated devices: all remain enumerated and automatic
  selection fails with `ambiguous_selector`; the caller must pass one exact
  selector.
- If integrated devices are opted in and exactly one compatible dedicated GPU
  exists, that dedicated GPU is selected automatically. The integrated GPU
  remains explicitly selectable. If there is no unique dedicated choice,
  multiple compatible devices remain ambiguous.
- Integrated GPUs are never silently preferred or activated. With default
  policy they are excluded; opt-in permits evaluation and explicit selection.
- One worker still owns one selected GPU. This API does not start concurrent
  multi-GPU mining.

The worker re-enumerates and resolves the selector before `hipSetDevice`.
For `--server` and `--run-batch`, it then checks current free memory and
runs the exact signed-INT8, field arithmetic, mask and kernel self-test before
loading the 6.44 GB model. On integrated GPUs it also requires at least 2 GiB
of system `MemAvailable` beyond the calculated 7,767,843,456-byte engine
requirement.

The default `gfx1100` rocBLAS solution IDs remain architecture-scoped. An
unrecognized architecture uses the standard rocBLAS selection unless an
advanced user explicitly supplies `--solution`.

## Exit codes

| Code | Error code | Meaning |
| ---: | --- | --- |
| 0 | — | Inventory or selection succeeded. |
| 2 | `invalid_arguments`, `invalid_configuration` | Invalid CLI or integrated-policy value. |
| 3 | `hip_runtime_unavailable` | HIP library or required symbols unavailable. |
| 4 | `hip_discovery_failed` | HIP enumeration failed. |
| 5 | `invalid_selector` | Selector syntax is invalid. |
| 6 | `ambiguous_selector` | No unique compatible dedicated choice, several compatible dedicated devices, or duplicate stable ID. |
| 7 | `no_qualified_device` | No compatible device under current build/policy. |
| 8 | `architecture_not_compiled`, `device_not_compatible` | Worker has no usable code object. |
| 9 | `device_not_found` | Exact selector did not match. |
| 10 | `integrated_device_disabled`, `integrated_status_unknown` | Safe integrated policy blocked selection. |
| 11 | `rocblas_architecture_unavailable` | Packaged rocBLAS lacks the architecture. |
| 12 | `insufficient_memory` | ProductionV4 batch-32 memory floor not met. |
| 13 | `capability_not_supported` | Required workgroup size is unavailable. |

Expected errors retain the full inventory and structured `error`. The API
does not report pool counters, temperature, power, clocks or fan data; those
are not consumed by the v1.0.13 mining view.
