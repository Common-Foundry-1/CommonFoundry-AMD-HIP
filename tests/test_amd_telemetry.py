#!/usr/bin/env python3
"""Telemetry, nvidia-smi probe, mining screen and WSL prepare tests.

Added by the Common Foundry project. No GPU, driver or network is used:
sysfs, AMD SMI, the coordinator and the ROCm download are all simulated.
"""

from __future__ import annotations

import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
UUID_RE = re.compile(r"^GPU-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def load(name: str, path: Path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def coordinator_accepts(row: str) -> list[float | None]:
    """Python port of the v1.0.13 coordinator's parse_nvidia_smi_csv rules."""
    columns = [column.strip() for column in row.split(",")]
    assert len(columns) == 11, row
    assert int(columns[0]) >= 0 and UUID_RE.match(columns[1]) and len(columns[1]) == 40, row
    values = []
    for column in columns[2:]:
        if column == "" or column == "-" or "N/A" in column.upper():
            values.append(None)
            continue
        number = float(column)
        assert number >= 0 and number == number, row
        values.append(number)
    return values


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text + "\n")


def fake_sysfs(root: Path) -> Path:
    device = root / "0000:0a:00.0"
    for name, text in {
        "vendor": "0x1002", "class": "0x030000", "product_name": "AMD Radeon RX 7900 XTX",
        "gpu_busy_percent": "99", "mem_info_vram_used": str(9 * 1024 ** 3),
        "mem_info_vram_total": str(24 * 1024 ** 3),
        "pp_dpm_sclk": "0: 500Mhz\n1: 2482Mhz *\n2: 2500Mhz",
        "pp_dpm_mclk": "0: 96Mhz\n3: 1249Mhz *",
    }.items():
        write(device / name, text)
    hwmon = device / "hwmon" / "hwmon3"
    for name, text in {
        "power1_average": "312500000", "power1_cap": "355000000",
        "temp1_label": "edge", "temp1_input": "61000", "temp2_label": "junction",
        "temp2_input": "78500", "temp3_label": "mem", "temp3_input": "72000",
        "fan1_input": "1650", "pwm1": "138", "pwm1_max": "255",
    }.items():
        write(hwmon / name, text)
    # An NVIDIA card in the same box must be ignored.
    write(root / "0000:01:00.0" / "vendor", "0x10de")
    write(root / "0000:01:00.0" / "class", "0x030000")
    return device


def fake_amdsmi(root: Path) -> Path:
    package = root / "amdsmi"
    write(package / "__init__.py", """
from enum import IntEnum
print("noise from the AMD wrapper that must not reach stdout")
class AmdSmiInitFlags(IntEnum):
    INIT_AMD_GPUS = 2
class AmdSmiTemperatureType(IntEnum):
    EDGE = 0
    HOTSPOT = 1
    VRAM = 2
class AmdSmiTemperatureMetric(IntEnum):
    CURRENT = 0
class AmdSmiClkType(IntEnum):
    GFX = 0
    MEM = 4
class AmdSmiException(Exception):
    pass
def amdsmi_init(flag): pass
def amdsmi_get_processor_handles(): return ["igpu", "dgpu"]
def amdsmi_get_gpu_device_bdf(h): return {"igpu": "0000:0e:00.0", "dgpu": "0000:03:00.0"}[h]
def amdsmi_get_gpu_asic_info(h):
    return {"market_name": "AMD Radeon RX 7900 XTX" if h == "dgpu" else "AMD Radeon Graphics",
            "target_graphics_version": "gfx1100" if h == "dgpu" else "gfx1036"}
def amdsmi_get_gpu_vram_usage(h): return {"vram_total": 24560 if h == "dgpu" else 512, "vram_used": 9300}
def amdsmi_get_power_info(h):
    return {"socket_power": 301, "current_socket_power": "N/A", "average_socket_power": 301, "power_limit": 339}
def amdsmi_get_temp_metric(h, kind, metric):
    if kind == AmdSmiTemperatureType.VRAM:
        raise AmdSmiException("not supported")
    return {0: 58, 1: 74}[int(kind)]
def amdsmi_get_gpu_activity(h): return {"gfx_activity": 98, "umc_activity": 40, "mm_activity": "N/A"}
def amdsmi_get_clock_info(h, kind): return {"clk": 2450 if kind == AmdSmiClkType.GFX else 1250}
def amdsmi_get_gpu_fan_speed(h, index): return 45
def amdsmi_get_gpu_fan_speed_max(h, index): return 100
""")
    return root


STATS_LINE = ("MINER STATS | GPU 0 (GPU-00000000-0000-0000-0000-000000000000) | height {height} | "
              "hashrate {rate} FW/s | accepted {a} | rejected {r} | stale {s} | blocks 0 | "
              "credit {c} atoms | power 312.50 W | efficiency 180000.00 FW/kWh | temp 61.00 C | uptime 0h 0m 5s")


def main() -> int:
    telemetry = load("amd_gpu_telemetry", TOOLS / "amd_gpu_telemetry.py")
    screen_module = load("cmfd_amd_screen", TOOLS / "cmfd-amd-screen")
    cases = 0
    with tempfile.TemporaryDirectory(prefix="cmfd-telemetry-tests-") as temporary:
        base = Path(temporary)
        sysfs = base / "sysfs"
        fake_sysfs(sysfs)
        native_env = dict(os.environ, CMFD_HIP_SYSFS_PCI_ROOT=str(sysfs),
                          CMFD_HIP_DXG_DEVICE=str(base / "no-dxg"))
        native_env.pop("CMFD_HIP_TELEMETRY_CACHE", None)
        native_env.pop("CMFD_HIP_TELEMETRY_PCI", None)

        # 1. Native sysfs readings and units.
        os.environ.update({"CMFD_HIP_SYSFS_PCI_ROOT": str(sysfs)})
        sample = telemetry.SysfsBackend(None).sample()
        assert sample["pci_bus_id"] == "0000:0a:00.0" and sample["name"] == "AMD Radeon RX 7900 XTX"
        assert abs(sample["power_w"] - 312.5) < 1e-6 and abs(sample["power_limit_w"] - 355) < 1e-6
        assert (sample["temp_edge_c"], sample["temp_hotspot_c"], sample["temp_mem_c"]) == (61.0, 78.5, 72.0)
        assert sample["fan_rpm"] == 1650 and abs(sample["fan_percent"] - 138 * 100 / 255) < 1e-6
        assert sample["load_percent"] == 99 and sample["core_clock_mhz"] == 2482 and sample["mem_clock_mhz"] == 1249
        assert sample["vram_used_mib"] == 9216 and sample["vram_total_mib"] == 24576
        cases += 1

        # 2. Explicit PCI selection, including HIP's pci: selector form.
        assert telemetry.SysfsBackend(telemetry.normalize_pci("pci:0000:0A:00.0")).device.name == "0000:0a:00.0"
        try:
            telemetry.SysfsBackend("0000:99:00.0")
            raise AssertionError("missing GPU accepted")
        except telemetry.TelemetryUnavailable:
            pass
        cases += 1

        # 3. Coordinator row: 11 columns, numbers or N/A, placeholder UUID.
        values = coordinator_accepts(telemetry.nvidia_csv_row(sample))
        assert values[0] == 312.5 and values[2] == 61.0 and values[8] == 24576.0
        assert coordinator_accepts(telemetry.nvidia_csv_row({})) == [None] * 9
        cases += 1

        # 4. CLI against sysfs.
        result = subprocess.run([sys.executable, "-I", str(TOOLS / "amd_gpu_telemetry.py"), "--nvidia-csv"],
                                env=native_env, capture_output=True, text=True, check=True)
        coordinator_accepts(result.stdout.strip())
        cases += 1

        # 5. WSL AMD SMI backend picks the dedicated GPU and keeps stdout clean.
        smi_path = fake_amdsmi(base / "amdsmi-site")
        dxg = base / "dxg"
        dxg.write_text("")
        wsl_env = dict(native_env, CMFD_HIP_DXG_DEVICE=str(dxg), CMFD_HIP_AMDSMI_PYTHONPATH=str(smi_path))
        result = subprocess.run([sys.executable, "-I", str(TOOLS / "amd_gpu_telemetry.py"), "--architecture"],
                                env=wsl_env, capture_output=True, text=True, check=True)
        assert result.stdout == "gfx1100\n", result.stdout
        result = subprocess.run([sys.executable, "-I", str(TOOLS / "amd_gpu_telemetry.py"), "--json"],
                                env=wsl_env, capture_output=True, text=True, check=True)
        wsl_sample = json.loads(result.stdout)
        assert wsl_sample["backend"] == "amdsmi-wsl" and wsl_sample["pci_bus_id"] == "0000:03:00.0"
        assert wsl_sample["power_w"] == 301 and wsl_sample["power_limit_w"] == 339
        assert wsl_sample["temp_edge_c"] == 58 and wsl_sample["temp_hotspot_c"] == 74 and wsl_sample["temp_mem_c"] is None
        assert wsl_sample["fan_percent"] == 45 and wsl_sample["core_clock_mhz"] == 2450
        assert wsl_sample["vram_total_mib"] == 24560 and wsl_sample["load_percent"] == 98
        cases += 1

        # 6. WSL without AMD SMI installed fails clearly (exit 3, nothing on stdout).
        missing_env = dict(wsl_env, CMFD_HIP_AMDSMI_PYTHONPATH=str(base / "absent"))
        result = subprocess.run([sys.executable, "-I", str(TOOLS / "amd_gpu_telemetry.py"), "--architecture"],
                                env=missing_env, capture_output=True, text=True)
        assert result.returncode == 3 and result.stdout == "" and "wsl-setup.sh" in result.stderr
        cases += 1

        # 7. nvidia-smi probe: fresh cache, direct read, placeholder, -L, bad args.
        probe = str(TOOLS / "nvidia-smi")
        query = [probe, "--query-gpu=index,uuid", "--format=csv,noheader,nounits"]
        cache = base / "telemetry.json"
        telemetry.write_cache(str(cache), sample)
        cached_env = dict(native_env, CMFD_HIP_TELEMETRY_CACHE=str(cache),
                          CMFD_HIP_SYSFS_PCI_ROOT=str(base / "empty"))
        row = subprocess.run(query, env=cached_env, capture_output=True, text=True, check=True).stdout.strip()
        assert coordinator_accepts(row)[0] == 312.5
        os.utime(str(cache) + ".csv", (time.time() - 60, time.time() - 60))
        row = subprocess.run(query, env=cached_env, capture_output=True, text=True, check=True).stdout.strip()
        assert coordinator_accepts(row) == [None] * 9, row
        row = subprocess.run(query, env=native_env, capture_output=True, text=True, check=True).stdout.strip()
        assert coordinator_accepts(row)[0] == 312.5
        listed = subprocess.run([probe, "-L"], env=dict(native_env, CMFD_HIP_GPU_NAME="AMD Radeon RX 7800 XT"),
                                capture_output=True, text=True, check=True).stdout
        assert listed.startswith("GPU 0: AMD Radeon RX 7800 XT (UUID: GPU-0000")
        assert subprocess.run([probe, "-q"], env=native_env, capture_output=True).returncode == 2
        cases += 1

        # 8. Screen parser follows the coordinator's real output formats.
        miner = screen_module.Miner()
        for line in ("Pool: cmfd+tls://203.0.113.5:7000?pin=" + "b" * 64, "Payout: " + "a" * 64,
                     "Worker: amd-hip-0e00", "GPU 0: GPU-00000000-0000-0000-0000-000000000000",
                     "Connected to pool at height 13904.",
                     "CMFD_HIP_REPLAY mode=search_batch nonces=32 seconds=2.032000 fw_per_second=15.748031 "
                     "wall_seconds=2.046000 effective_fw_per_second=15.640274 graph=on solution=-1140855025",
                     STATS_LINE.format(height=13905, rate="15.53", a=3, r=1, s=1, c=250_000),
                     STATS_LINE.format(height=13906, rate="15.47", a=4, r=1, s=1, c=300_000)):
            miner.parse(line)
        assert miner.status == "Connected" and miner.height == 13906 and miner.worker == "amd-hip-0e00"
        assert (miner.accepted, miner.rejected, miner.stale, miner.credit) == (4, 1, 1, 300_000)
        assert abs(miner.gpu_rate - 15.748031) < 1e-9 and miner.last_share is not None
        miner.telemetry = sample
        view = screen_module.Screen(miner, "AMD Radeon RX 7900 XTX", "gfx1100", "/tmp/miner.log")
        view.color = False
        text = "\n".join(view.lines(100, stopping=False))
        for expected in ("15.47 FW/s", "avg 15.50 FW/s", "GPU batch 15.75 FW/s", "4 accepted", "1 rejected",
                         "80.0%", "0.00300000 CMFD", "312 W", "355 W", "61°C edge", "78°C hotspot",
                         "2,482 MHz core", "9.0 / 24.0 GB", "cmfd+tls://203.0.113.5:7000", "aaaaaaaa…aaaaaaaa",
                         "13,906", "gfx1100", "Linux · amdgpu"):
            assert expected in text, (expected, text)
        assert "pin=" not in text
        assert all(len(line) <= 99 for line in view.lines(100, stopping=True))
        cases += 1

        # 9. Screen wrapper end to end without a terminal: passthrough, log, cache, exit code.
        fake_miner = base / "cmfd-miner"
        fake_miner.write_text("#!/usr/bin/env bash\n"
                              "printf 'Pool: cmfd+tls://127.0.0.1:1\\n'\n"
                              f"printf '%s\\n' '{STATS_LINE.format(height=1, rate='15.50', a=1, r=0, s=0, c=0)}'\n"
                              "printf 'worker stderr line\\n' >&2\n"
                              "exit 7\n")
        fake_miner.chmod(0o755)
        log = base / "logs" / "miner.log"
        screen_env = dict(native_env, CMFD_HIP_TELEMETRY_CACHE=str(base / "screen-cache.json"))
        result = subprocess.run([sys.executable, "-I", str(TOOLS / "cmfd-amd-screen"), "--log", str(log), "--",
                                 str(fake_miner)], env=screen_env, capture_output=True, text=True)
        assert result.returncode == 7, result
        assert "MINER STATS" in result.stdout and "worker stderr line" in result.stdout
        assert "1 accepted" in result.stdout and str(log) in result.stdout
        logged = log.read_text()
        assert "Pool: cmfd+tls://127.0.0.1:1" in logged and "worker stderr line" in logged
        coordinator_accepts((base / "screen-cache.json.csv").read_text().strip())
        cases += 1

        # 10. Runtime manager on WSL: auto prepare uses the AMD SMI architecture tarball.
        manager = str(ROOT / "runtime" / "cmfd-hip-runtime")
        source = base / "rocm-source" / "rocm"
        (source / ".info").mkdir(parents=True)
        (source / ".info" / "version").write_text("7.14.0\n")
        (source / "lib" / "rocblas" / "library").mkdir(parents=True)
        (source / "lib" / "libamdhip64.so.7").write_bytes(b"hip")
        (source / "lib" / "librocblas.so.5").write_bytes(b"rocblas")
        (source / "lib" / "rocblas" / "library" / "TensileLibrary_gfx1100.dat").write_bytes(b"x")
        bundle = base / "therock-gfx110x.tar.gz"
        with tarfile.open(bundle, "w:gz") as archive:
            archive.add(source, arcname="rocm")
        catalog = base / "packages.tsv"
        catalog.write_text("# fixture\nrunfile\tauto\tauto\t7.14.0\tfile:///never-used.run\t1\t-\n"
                           f"tar\tgfx110x\tgfx1100,gfx1101\t7.14.0\tfile://{bundle}\t{bundle.stat().st_size}\t-\n")
        bin_dir = base / "bin"
        bin_dir.mkdir()
        (bin_dir / "curl").write_text("#!/usr/bin/env bash\nout=''\nwhile (($#)); do\n"
                                      "  [[ $1 == --output ]] && { shift; out=$1; }\n  shift || true\ndone\n"
                                      f"cp -- {str(bundle)!r} \"$out\"\n")
        (bin_dir / "curl").chmod(0o755)
        helper = base / "fake_telemetry.py"
        helper.write_text("import sys\nprint('gfx1100' if '--architecture' in sys.argv else '')\n")
        manager_env = dict(os.environ, CMFD_HIP_STATE_DIR=str(base / "state"), CMFD_HIP_PACKAGE_CATALOG=str(catalog),
                           CMFD_HIP_TEST_ALLOW_FILE_URL="1", CMFD_HIP_DXG_DEVICE=str(dxg),
                           CMFD_HIP_TELEMETRY=str(helper), PATH=f"{bin_dir}:{os.environ['PATH']}")
        for key in ("CMFD_HIP_RUNTIME_ROOT", "CMFD_HIP_RUNTIME_MANIFEST"):
            manager_env.pop(key, None)
        status = json.loads(subprocess.run([manager, "status"], env=dict(manager_env, CMFD_HIP_RUNTIME_ROOT=str(base / "x")),
                                           capture_output=True, text=True, check=True).stdout.splitlines()[-1])
        assert status["system"]["dxg"] == "accessible"
        assert status["system"]["wsl"] is (not Path("/dev/kfd").exists())
        if not Path("/dev/kfd").exists():
            result = subprocess.run([manager, "prepare", "--authorize-download"], env=manager_env,
                                    capture_output=True, text=True)
            assert result.returncode == 0, result
            ready = json.loads(result.stdout.splitlines()[-1])
            assert ready["status"] == "ready" and "gfx1100" in ready["architectures"]
            manifest = (base / "state" / "active.manifest").read_text()
            assert "architecture=gfx1100" in manifest and "source=official_amd_gfx110x" in manifest
            assert hashlib.sha256(bundle.read_bytes()).hexdigest() in manifest
            # No AMD GPU visible to AMD SMI: a clear setup error, not the runfile.
            helper.write_text("raise SystemExit(3)\n")
            result = subprocess.run([manager, "prepare", "--authorize-download"],
                                    env=dict(manager_env, CMFD_HIP_STATE_DIR=str(base / "state2")),
                                    capture_output=True, text=True)
            assert result.returncode == 41 and "wsl_setup_required" in result.stdout, result
        cases += 1

    assert cases == 10, cases
    print(f"CMFD_AMD_TELEMETRY_TEST PASS cases={cases} gpu=simulated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
