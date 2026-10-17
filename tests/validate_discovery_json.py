#!/usr/bin/env python3
import json
import os
import subprocess
import sys


def validate(document: object) -> None:
    assert isinstance(document, dict)
    assert document["schema"] == "common-foundry.amd-hip.discovery"
    assert document["schema_version"] == 1
    assert document["backend"] == "amd-hip"
    assert document["status"] in {"ok", "error"}
    assert document["qualified_architectures"] == ["gfx1036", "gfx1100"]
    assert "gfx1036" in document["compiled_architectures"]
    assert "gfx1100" in document["compiled_architectures"]
    assert isinstance(document["rocblas_architectures"], list)
    assert document["physically_tested_architectures"] == ["gfx1036", "gfx1100"]
    assert isinstance(document["runtime"]["available"], bool)
    assert isinstance(document["runtime"]["root"], str)
    assert isinstance(document["runtime"]["source"], str)
    assert isinstance(document["runtime"]["version"], str)
    assert document["runtime"]["error"] is None or isinstance(
        document["runtime"]["error"], str
    )
    assert isinstance(document["policy"]["allow_integrated"], bool)
    assert document["policy"]["estimated_allocation_bytes"] == 6_962_537_088
    assert document["policy"]["memory_safety_margin_bytes"] == 768 * 1024**2
    assert document["policy"]["minimum_production_v4_memory_bytes"] == 7_767_843_456
    assert isinstance(document["devices"], list)
    assert document["error"] is None or isinstance(document["error"]["code"], str)
    for device in document["devices"]:
        assert isinstance(device["hip_index"], int)
        assert isinstance(device["name"], str)
        assert isinstance(device["architecture"], str)
        assert isinstance(device["vram_bytes"], int)
        assert device["available_memory_bytes"] is None or isinstance(
            device["available_memory_bytes"], int
        )
        assert device["integrated"] is None or isinstance(device["integrated"], bool)
        assert device["device_type"] in {"discrete", "integrated", "unknown"}
        assert isinstance(device["max_threads_per_block"], int)
        assert isinstance(device["warp_size"], int)
        assert isinstance(device["compute_units"], int)
        assert device["uuid"] is None or isinstance(device["uuid"], str)
        assert device["pci_bus_id"] is None or isinstance(device["pci_bus_id"], str)
        assert device["stable_id"] is None or isinstance(device["stable_id"], str)
        assert device["selector_stability"] in {"hardware", "topology", "session"}
        assert isinstance(device["architecture_compiled"], bool)
        assert isinstance(device["rocblas_architecture_available"], bool)
        assert isinstance(device["total_memory_sufficient"], bool)
        assert isinstance(device["available_memory_sufficient"], bool)
        assert isinstance(device["workgroup_supported"], bool)
        assert isinstance(device["integrated_allowed"], bool)
        assert isinstance(device["physically_tested"], bool)
        assert isinstance(device["runtime_validation_required"], bool)
        assert isinstance(device["compatible"], bool)
        assert isinstance(device["qualified"], bool)
        assert device["qualified"] == device["compatible"]


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: validate_discovery_json.py TEST_BINARY DISCOVERY_BINARY")

    fixture = subprocess.run(
        [sys.argv[1], "--json-fixtures"], check=True, text=True, capture_output=True
    )
    documents = [json.loads(line) for line in fixture.stdout.splitlines() if line]
    assert len(documents) >= 12
    for document in documents:
        validate(document)

    live = subprocess.run([sys.argv[2], "--list"], check=False, text=True, capture_output=True)
    live_lines = [line for line in live.stdout.splitlines() if line]
    assert len(live_lines) == 1
    live_document = json.loads(live_lines[0])
    validate(live_document)
    if live.returncode == 0:
        assert live_document["status"] == "ok"
    else:
        assert live_document["status"] == "error"
        assert live_document["error"] is not None

    integrated_environment = dict(os.environ)
    integrated_environment["CMFD_HIP_ALLOW_INTEGRATED"] = "1"
    integrated = subprocess.run(
        [sys.argv[2], "--list"],
        check=False,
        text=True,
        capture_output=True,
        env=integrated_environment,
    )
    integrated_document = json.loads(integrated.stdout)
    validate(integrated_document)
    assert integrated_document["policy"]["allow_integrated"] is True

    invalid_environment = dict(os.environ)
    invalid_environment["CMFD_HIP_ALLOW_INTEGRATED"] = "maybe"
    invalid_policy = subprocess.run(
        [sys.argv[2], "--list"],
        check=False,
        text=True,
        capture_output=True,
        env=invalid_environment,
    )
    invalid_policy_document = json.loads(invalid_policy.stdout)
    validate(invalid_policy_document)
    assert invalid_policy.returncode == 2
    assert invalid_policy_document["error"]["code"] == "invalid_configuration"

    invalid_cli = subprocess.run(
        [sys.argv[2], "--auto-select", "--select", "hip:0"],
        check=False,
        text=True,
        capture_output=True,
    )
    assert invalid_cli.returncode == 2
    invalid_document = json.loads(invalid_cli.stdout)
    validate(invalid_document)
    assert invalid_document["error"]["code"] == "invalid_arguments"

    print(f"CMFD_HIP_DISCOVERY_JSON_TEST PASS fixtures={len(documents)} live_status={live_document['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
