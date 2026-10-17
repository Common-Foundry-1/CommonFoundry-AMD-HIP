#!/usr/bin/env python3
"""AMD GPU telemetry for the Common Foundry AMD HIP miner.

Added by the Common Foundry project. Standard library only.

Backends:
  sysfs   native Linux amdgpu driver (/sys/bus/pci/devices/*/hwmon)
  amdsmi  WSL2, through AMD's official WSL AMD SMI Python package
          (rocdxg-amd-smi-lib, installed under /opt/rocm-wsl)

Every value is reported in the unit named by its key; a missing sensor is None
(JSON null, CSV "N/A"). Nothing here changes GPU settings.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import re
import sys
import time

PLACEHOLDER_UUID = "GPU-00000000-0000-0000-0000-000000000000"
AMDSMI_PYTHONPATH = "/opt/rocm-wsl/share/amd_smi"
FIELDS = (
    "power_w", "power_limit_w", "temp_edge_c", "temp_hotspot_c", "temp_mem_c",
    "fan_percent", "fan_rpm", "load_percent", "core_clock_mhz", "mem_clock_mhz",
    "vram_used_mib", "vram_total_mib",
)


class TelemetryUnavailable(Exception):
    pass


def dxg_present() -> bool:
    return Path(os.environ.get("CMFD_HIP_DXG_DEVICE", "/dev/dxg")).exists()


def normalize_pci(value: str | None) -> str | None:
    if not value:
        return None
    value = value.strip().lower()
    if value.startswith("pci:"):
        value = value[4:]
    if value.count(":") == 1:
        value = "0000:" + value
    return value or None


def number(value: object) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).strip())
    except ValueError:
        return None


def empty_sample() -> dict[str, object]:
    sample: dict[str, object] = {key: None for key in FIELDS}
    sample.update({"name": None, "architecture": None, "pci_bus_id": None, "backend": None})
    return sample


# --------------------------------------------------------------------------
# Native Linux: amdgpu sysfs


def read_text(path: Path) -> str | None:
    try:
        return path.read_text().strip()
    except OSError:
        return None


def read_number(path: Path, scale: float = 1.0) -> float | None:
    value = number(read_text(path))
    return None if value is None else value * scale


def current_dpm_mhz(path: Path) -> float | None:
    text = read_text(path)
    if not text:
        return None
    for line in text.splitlines():
        if line.rstrip().endswith("*"):
            for token in line.split():
                if token.lower().endswith("mhz"):
                    return number(token[:-3])
    return None


class SysfsBackend:
    name = "sysfs"

    def __init__(self, pci: str | None) -> None:
        root = Path(os.environ.get("CMFD_HIP_SYSFS_PCI_ROOT", "/sys/bus/pci/devices"))
        devices = []
        for device in sorted(root.glob("*")):
            if (read_text(device / "vendor") or "").lower() != "0x1002":
                continue
            if not (read_text(device / "class") or "").lower().startswith("0x03"):
                continue
            if not (device / "mem_info_vram_total").exists():
                continue
            devices.append(device)
        if not devices:
            raise TelemetryUnavailable("no amdgpu device in sysfs")
        if pci:
            matches = [device for device in devices if device.name.lower() == pci]
            if not matches:
                raise TelemetryUnavailable(f"AMD GPU {pci} is not in sysfs")
            self.device = matches[0]
        else:
            self.device = max(devices, key=lambda d: read_number(d / "mem_info_vram_total") or 0)
        hwmons = sorted((self.device / "hwmon").glob("hwmon*"))
        self.hwmon = hwmons[0] if hwmons else None

    def sample(self) -> dict[str, object]:
        device, hwmon = self.device, self.hwmon
        sample = empty_sample()
        sample.update({"backend": self.name, "pci_bus_id": device.name.lower(),
                       "name": read_text(device / "product_name") or None})
        sample["load_percent"] = read_number(device / "gpu_busy_percent")
        sample["vram_used_mib"] = read_number(device / "mem_info_vram_used", 1 / 1048576)
        sample["vram_total_mib"] = read_number(device / "mem_info_vram_total", 1 / 1048576)
        sample["core_clock_mhz"] = current_dpm_mhz(device / "pp_dpm_sclk")
        sample["mem_clock_mhz"] = current_dpm_mhz(device / "pp_dpm_mclk")
        if hwmon is None:
            return sample
        power = read_number(hwmon / "power1_average", 1e-6)
        if power is None:
            power = read_number(hwmon / "power1_input", 1e-6)
        sample["power_w"] = power
        sample["power_limit_w"] = read_number(hwmon / "power1_cap", 1e-6)
        labels = {"edge": "temp_edge_c", "junction": "temp_hotspot_c", "mem": "temp_mem_c"}
        for label_file in sorted(hwmon.glob("temp*_label")):
            key = labels.get((read_text(label_file) or "").lower())
            if key:
                sample[key] = read_number(hwmon / label_file.name.replace("_label", "_input"), 1e-3)
        if sample["temp_edge_c"] is None:
            sample["temp_edge_c"] = read_number(hwmon / "temp1_input", 1e-3)
        sample["fan_rpm"] = read_number(hwmon / "fan1_input")
        pwm = read_number(hwmon / "pwm1")
        pwm_max = read_number(hwmon / "pwm1_max") or 255.0
        if pwm is not None and pwm_max > 0:
            sample["fan_percent"] = pwm * 100.0 / pwm_max
        for clock_label, key in (("sclk", "core_clock_mhz"), ("mclk", "mem_clock_mhz")):
            for label_file in sorted(hwmon.glob("freq*_label")):
                if (read_text(label_file) or "").lower() == clock_label:
                    value = read_number(hwmon / label_file.name.replace("_label", "_input"), 1e-6)
                    if value is not None:
                        sample[key] = value
        return sample


# --------------------------------------------------------------------------
# WSL2: AMD's official WSL AMD SMI package


def load_amdsmi():
    path = os.environ.get("CMFD_HIP_AMDSMI_PYTHONPATH", AMDSMI_PYTHONPATH)
    if not Path(path, "amdsmi").is_dir():
        raise TelemetryUnavailable(
            f"AMD SMI for WSL is not installed ({path}); run bin/wsl-setup.sh")
    if path not in sys.path:
        sys.path.insert(0, path)
    # The AMD wrapper prints loader errors to stdout; keep stdout clean.
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            import amdsmi  # type: ignore
        except Exception as error:  # noqa: BLE001
            raise TelemetryUnavailable(f"cannot load AMD SMI: {error}") from error
    return amdsmi


class AmdSmiBackend:
    name = "amdsmi-wsl"

    def __init__(self, pci: str | None) -> None:
        self.smi = smi = load_amdsmi()
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                smi.amdsmi_init(smi.AmdSmiInitFlags.INIT_AMD_GPUS)
                handles = list(smi.amdsmi_get_processor_handles())
            except Exception as error:  # noqa: BLE001
                raise TelemetryUnavailable(f"AMD SMI initialization failed: {error}") from error
        if not handles:
            raise TelemetryUnavailable("AMD SMI found no AMD GPU")
        gpus = []
        for handle in handles:
            bdf = normalize_pci(self.call(smi.amdsmi_get_gpu_device_bdf, handle))
            asic = self.call(smi.amdsmi_get_gpu_asic_info, handle) or {}
            vram = self.call(smi.amdsmi_get_gpu_vram_usage, handle) or {}
            gpus.append((handle, bdf, asic, number(vram.get("vram_total")) or 0.0))
        if pci:
            matches = [gpu for gpu in gpus if gpu[1] == pci]
            if not matches:
                raise TelemetryUnavailable(f"AMD GPU {pci} is not reported by AMD SMI")
            chosen = matches[0]
        else:
            chosen = max(gpus, key=lambda gpu: gpu[3])
        self.handle, self.pci, asic, _ = chosen
        name = asic.get("market_name")
        self.gpu_name = name if name and name != "N/A" else None
        arch = str(asic.get("target_graphics_version") or "").lower()
        self.architecture = arch if re.fullmatch(r"gfx[0-9]{1,2}[0-9a-f]{2}", arch) else None

    @staticmethod
    def call(function, *arguments):
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                return function(*arguments)
        except Exception:  # noqa: BLE001 - every sensor is optional
            return None

    def sample(self) -> dict[str, object]:
        smi, handle = self.smi, self.handle
        sample = empty_sample()
        sample.update({"backend": self.name, "pci_bus_id": self.pci, "name": self.gpu_name,
                       "architecture": self.architecture})
        power = self.call(smi.amdsmi_get_power_info, handle) or {}
        for key in ("current_socket_power", "average_socket_power", "socket_power"):
            value = number(power.get(key))
            if value is not None and value < 65535:
                sample["power_w"] = value
                break
        limit = number(power.get("power_limit"))
        sample["power_limit_w"] = limit if limit is not None and limit < 65535 else None
        temperature = smi.AmdSmiTemperatureType
        metric = smi.AmdSmiTemperatureMetric.CURRENT
        for kind, key in ((temperature.EDGE, "temp_edge_c"), (temperature.HOTSPOT, "temp_hotspot_c"),
                          (temperature.VRAM, "temp_mem_c")):
            value = number(self.call(smi.amdsmi_get_temp_metric, handle, kind, metric))
            sample[key] = value if value is not None and value < 65535 else None
        activity = self.call(smi.amdsmi_get_gpu_activity, handle) or {}
        sample["load_percent"] = number(activity.get("gfx_activity"))
        for kind, key in ((smi.AmdSmiClkType.GFX, "core_clock_mhz"), (smi.AmdSmiClkType.MEM, "mem_clock_mhz")):
            clock = self.call(smi.amdsmi_get_clock_info, handle, kind) or {}
            sample[key] = number(clock.get("clk"))
        vram = self.call(smi.amdsmi_get_gpu_vram_usage, handle) or {}
        sample["vram_used_mib"] = number(vram.get("vram_used"))
        sample["vram_total_mib"] = number(vram.get("vram_total"))
        fan = number(self.call(smi.amdsmi_get_gpu_fan_speed, handle, 0))
        fan_max = number(self.call(smi.amdsmi_get_gpu_fan_speed_max, handle, 0))
        if fan is not None and fan_max:
            sample["fan_percent"] = fan * 100.0 / fan_max
        return sample


# --------------------------------------------------------------------------


def open_backend(pci: str | None = None):
    pci = normalize_pci(pci or os.environ.get("CMFD_HIP_TELEMETRY_PCI"))
    if dxg_present() and not Path("/dev/kfd").exists():
        return AmdSmiBackend(pci)
    return SysfsBackend(pci)


def nvidia_csv_row(sample: dict[str, object] | None) -> str:
    """One row in the order the v1.0.13 coordinator queries from nvidia-smi."""
    sample = sample or {}

    def field(key: str) -> str:
        value = sample.get(key)
        return "N/A" if value is None else f"{float(value):.2f}"

    keys = ("power_w", "power_limit_w", "temp_edge_c", "fan_percent", "load_percent",
            "core_clock_mhz", "mem_clock_mhz", "vram_used_mib", "vram_total_mib")
    return ", ".join(["0", PLACEHOLDER_UUID] + [field(key) for key in keys])


def write_cache(path: str, sample: dict[str, object]) -> None:
    """Atomically write <path> (JSON) and <path>.csv (coordinator row)."""
    sample = dict(sample, timestamp=time.time())
    for target, text in ((path, json.dumps(sample)), (path + ".csv", nvidia_csv_row(sample))):
        temporary = f"{target}.tmp.{os.getpid()}"
        with open(temporary, "w") as handle:
            handle.write(text + "\n")
        os.replace(temporary, target)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--json", action="store_true", help="print one sample as JSON (default)")
    mode.add_argument("--nvidia-csv", action="store_true", help="print the coordinator telemetry row")
    mode.add_argument("--architecture", action="store_true", help="print the gfx target (WSL only)")
    parser.add_argument("--pci", help="PCI bus id of the GPU (default: CMFD_HIP_TELEMETRY_PCI or largest VRAM)")
    arguments = parser.parse_args()
    try:
        backend = open_backend(arguments.pci)
        if arguments.architecture:
            architecture = getattr(backend, "architecture", None)
            if not architecture:
                raise TelemetryUnavailable("GPU architecture is only reported by AMD SMI on WSL")
            print(architecture)
            return 0
        sample = backend.sample()
    except TelemetryUnavailable as error:
        print(f"amd-gpu-telemetry: {error}", file=sys.stderr)
        return 3
    print(nvidia_csv_row(sample) if arguments.nvidia_csv else json.dumps(sample))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
