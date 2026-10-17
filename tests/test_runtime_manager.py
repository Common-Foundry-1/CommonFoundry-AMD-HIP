#!/usr/bin/env python3
"""Deterministic deployment tests; no network, driver, or real GPU is used."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time


def run(command: list[str], env: dict[str, str], expected: int | None = 0) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, env=env, text=True, capture_output=True, check=False)
    if expected is not None and result.returncode != expected:
        raise AssertionError(
            f"command {command!r} returned {result.returncode}, expected {expected}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
    return result


def document(result: subprocess.CompletedProcess[str]) -> dict[str, object]:
    lines = [line for line in result.stdout.splitlines() if line]
    assert lines, result
    return json.loads(lines[-1])


def make_runtime(root: Path, version: str, architectures: tuple[str, ...]) -> None:
    (root / ".info").mkdir(parents=True)
    (root / ".info" / "version").write_text(version + "\n")
    library = root / "lib"
    rocblas = library / "rocblas" / "library"
    rocblas.mkdir(parents=True)
    (library / "libamdhip64.so.7").write_bytes(b"fake-hip-" + version.encode())
    (library / "librocblas.so.5").write_bytes(b"fake-rocblas-" + version.encode())
    for architecture in architectures:
        (rocblas / f"TensileLibrary_fixture_{architecture}.dat").write_bytes(
            b"fixture-" + architecture.encode()
        )


def make_bundle(directory: Path, name: str, version: str, architectures: tuple[str, ...]) -> Path:
    source = directory / f"{name}-source" / "rocm"
    make_runtime(source, version, architectures)
    bundle = directory / f"{name}.tar.gz"
    with tarfile.open(bundle, "w:gz") as archive:
        archive.add(source, arcname="rocm")
    return bundle


def manager_env(base: Path) -> dict[str, str]:
    env = dict(os.environ)
    env.pop("CMFD_HIP_RUNTIME_ROOT", None)
    env.pop("CMFD_HIP_RUNTIME_MANIFEST", None)
    env["CMFD_HIP_STATE_DIR"] = str(base / "state")
    env["CMFD_HIP_DXG_DEVICE"] = str(base / "no-dxg")  # native Linux, even on a WSL host
    return env


def install_bundle(manager: str, bundle: Path, env: dict[str, str], architecture: str) -> dict[str, object]:
    digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
    return document(
        run(
            [manager, "prepare", "--bundle", str(bundle), "--sha256", digest,
             "--architecture", architecture],
            env,
        )
    )


def make_mock_curl(path: Path, source: Path | None, counter: Path, fail: bool) -> None:
    script = f"""#!/usr/bin/env bash
set -euo pipefail
printf x >> {str(counter)!r}
output=''
while (($#)); do
  if [[ "$1" == --output ]]; then shift; output=$1; fi
  shift || true
done
[[ -n "$output" ]]
"""
    if source is not None:
        script += f"cp -- {str(source)!r} \"$output\"\n"
    else:
        script += "printf partial >\"$output\"\n"
    script += "exit 1\n" if fail else "exit 0\n"
    path.write_text(script)
    path.chmod(0o755)


def make_catalog(path: Path, fmt: str, architecture: str, source: Path) -> None:
    path.write_text(
        "# schema=common-foundry.amd-hip.packages-v1\n"
        f"{fmt}\tfixture\t{architecture}\t7.14.0\tfile://{source}\t"
        f"{source.stat().st_size}\t-\n"
    )


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: test_runtime_manager.py MANAGER WORKER_WRAPPER LAUNCHER")
    manager = str(Path(sys.argv[1]).resolve())
    wrapper = str(Path(sys.argv[2]).resolve())
    launcher = str(Path(sys.argv[3]).resolve())
    cases = 0

    with tempfile.TemporaryDirectory(prefix="cmfd-runtime-tests-") as temporary:
        base = Path(temporary)

        # 1. No ROCm installed (explicit missing root prevents host fallback).
        env = manager_env(base / "missing")
        env["CMFD_HIP_RUNTIME_ROOT"] = str(base / "does-not-exist")
        status = document(run([manager, "status"], env))
        assert status["status"] == "needs_preparation"
        cases += 1

        # 2. Compatible ROCm and 3. incomplete installation.
        complete = base / "complete"
        make_runtime(complete, "7.14.0", ("gfx1100",))
        env["CMFD_HIP_RUNTIME_ROOT"] = str(complete)
        status = document(run([manager, "status"], env))
        assert status["runtime"]["ready"] is True
        cases += 1
        incomplete = base / "incomplete"
        (incomplete / "lib").mkdir(parents=True)
        (incomplete / "lib" / "libamdhip64.so.7").write_bytes(b"hip")
        env["CMFD_HIP_RUNTIME_ROOT"] = str(incomplete)
        status = document(run([manager, "status"], env))
        assert status["runtime"]["ready"] is False
        cases += 1

        # 4. A coherent but incompatible ROCm ABI family is rejected.
        incompatible = base / "incompatible-version"
        make_runtime(incompatible, "6.4.0", ("gfx1100",))
        env["CMFD_HIP_RUNTIME_ROOT"] = str(incompatible)
        incompatible_status = document(run([manager, "status"], env))
        assert incompatible_status["runtime"]["ready"] is False
        assert "requires the 7.14 ABI family" in incompatible_status["runtime"]["error"]
        cases += 1

        # 5. rocBLAS host library present but its architecture payload absent.
        no_arch = base / "no-arch"
        make_runtime(no_arch, "7.14.0", ("gfx1100",))
        for item in (no_arch / "lib" / "rocblas" / "library").iterdir():
            item.unlink()
        env["CMFD_HIP_RUNTIME_ROOT"] = str(no_arch)
        assert document(run([manager, "status"], env))["runtime"]["ready"] is False
        cases += 1

        bundle1100 = make_bundle(base, "runtime1100", "7.14.0", ("gfx1100",))
        bundle1036 = make_bundle(base, "runtime1036", "7.14.0", ("gfx1036",))

        # 6/7. Missing architecture is supplied by an atomic initial install.
        env = manager_env(base / "install")
        installed = install_bundle(manager, bundle1036, env, "gfx1036")
        assert installed["status"] == "ready" and "gfx1036" in installed["architectures"]
        assert (Path(env["CMFD_HIP_STATE_DIR"]) / "active.manifest").is_file()
        cases += 2

        # 8. Restart reuses the active runtime and never invokes curl.
        counter = base / "curl-counter"
        mock_curl = base / "mock-curl"
        make_mock_curl(mock_curl, None, counter, True)
        env["PATH"] = str(base) + os.pathsep + env["PATH"]
        reused = document(run([manager, "prepare", "--architecture", "gfx1036"], env))
        assert reused["reused"] is True and not counter.exists()
        cases += 1

        # 9. Interrupted download keeps a resumable .part and reports network failure.
        network_state = base / "network"
        env_net = manager_env(network_state)
        env_net["CMFD_HIP_RUNTIME_ROOT"] = str(base / "network-missing-runtime")
        catalog = base / "network.tsv"
        make_catalog(catalog, "tar", "gfx1100", bundle1100)
        env_net.update({
            "CMFD_HIP_PACKAGE_CATALOG": str(catalog),
            "CMFD_HIP_TEST_ALLOW_FILE_URL": "1",
            "PATH": str(base) + os.pathsep + env_net["PATH"],
        })
        shutil.copy2(mock_curl, base / "curl")
        (base / "curl").chmod(0o755)
        interrupted = document(run(
            [manager, "prepare", "--architecture", "gfx1100", "--authorize-download"],
            env_net,
            expected=38,
        ))
        assert interrupted["error"]["code"] == "network_unavailable"
        assert list((Path(env_net["CMFD_HIP_STATE_DIR"]) / "downloads").glob("*.part"))
        cases += 1

        # 10. A successful network download is atomically published without a .part suffix.
        success_env = manager_env(base / "network-success")
        success_env["CMFD_HIP_RUNTIME_ROOT"] = str(base / "network-success-missing")
        success_env.update({
            "CMFD_HIP_PACKAGE_CATALOG": str(catalog),
            "CMFD_HIP_TEST_ALLOW_FILE_URL": "1",
            "PATH": str(base) + os.pathsep + success_env["PATH"],
        })
        success_counter = base / "success-curl-counter"
        make_mock_curl(base / "curl", bundle1100, success_counter, False)
        downloaded = document(run(
            [manager, "prepare", "--architecture", "gfx1100", "--authorize-download"],
            success_env,
        ))
        download_dir = Path(success_env["CMFD_HIP_STATE_DIR"]) / "downloads"
        assert downloaded["status"] == "ready"
        assert (download_dir / bundle1100.name).is_file()
        assert not list(download_dir.glob("*.part"))
        assert (download_dir / f"{bundle1100.name}.sha256").is_file()
        cases += 1

        # 11. Corrupted local file fails its pinned SHA-256.
        bad = document(run(
            [manager, "prepare", "--bundle", str(bundle1100), "--sha256", "0" * 64,
             "--architecture", "gfx1100"],
            manager_env(base / "corrupt"),
            expected=27,
        ))
        assert bad["error"]["code"] == "bundle_corrupt"
        cases += 1

        # 12. A partial manifest is never accepted.
        partial_env = manager_env(base / "partial")
        partial_state = Path(partial_env["CMFD_HIP_STATE_DIR"])
        partial_state.mkdir(parents=True)
        (partial_state / "active.manifest").write_text(
            "schema=common-foundry.amd-hip.runtime-v1\ncomplete=0\n"
        )
        assert document(run([manager, "status"], partial_env))["runtime"]["ready"] is False
        cases += 1

        # 13. Version change is atomic and preserves the previous manifest.
        update_env = manager_env(base / "update")
        install_bundle(manager, bundle1100, update_env, "gfx1100")
        old_manifest = (Path(update_env["CMFD_HIP_STATE_DIR"]) / "active.manifest").read_text()
        bundle_new = make_bundle(base, "runtime-new", "7.14.1", ("gfx1100",))
        install_bundle(manager, bundle_new, update_env, "gfx1100")
        assert "7.14.1" in (Path(update_env["CMFD_HIP_STATE_DIR"]) / "active.manifest").read_text()
        assert (Path(update_env["CMFD_HIP_STATE_DIR"]) / "previous.manifest").read_text() == old_manifest
        cases += 1

        # 14. A changed GPU architecture cannot reuse an unrelated runtime.
        changed = document(run(
            [manager, "prepare", "--architecture", "gfx1036"], update_env, expected=35
        ))
        assert changed["error"]["code"] == "authorization_required"
        cases += 1

        # 15. A complete private runtime works offline, including deep verification.
        assert document(run([manager, "verify", "--deep"], update_env))["status"] == "ready"
        cases += 1

        # 16. Missing Internet is distinguished from missing authorization.
        assert interrupted["error"]["code"] == "network_unavailable"
        cases += 1

        # 17. Runfile prerequisite failure asks for system authorization; no sudo is run.
        fake_runfile = base / "fake.run"
        fake_runfile.write_text("#!/usr/bin/env bash\nexit 1\n")
        fake_runfile.chmod(0o755)
        runfile_catalog = base / "runfile.tsv"
        make_catalog(runfile_catalog, "runfile", "auto", fake_runfile)
        runfile_counter = base / "runfile-counter"
        make_mock_curl(base / "curl", fake_runfile, runfile_counter, False)
        runfile_env = manager_env(base / "runfile")
        runfile_env.update({
            "CMFD_HIP_RUNTIME_ROOT": str(base / "runfile-missing-runtime"),
            "CMFD_HIP_PACKAGE_CATALOG": str(runfile_catalog),
            "CMFD_HIP_TEST_ALLOW_FILE_URL": "1",
            "PATH": str(base) + os.pathsep + runfile_env["PATH"],
        })
        denied = document(run(
            [manager, "prepare", "--authorize-download"], runfile_env, expected=30
        ))
        assert denied["error"]["code"] == "system_authorization_required"
        cases += 1

        # 18. An unwritable state parent returns a structured permission error.
        permission_base = base / "permission"
        permission_base.mkdir()
        permission_base.chmod(0o500)
        permission_env = manager_env(permission_base)
        permission_env["CMFD_HIP_RUNTIME_ROOT"] = str(base / "permission-missing-runtime")
        try:
            denied_write = document(run(
                [manager, "prepare", "--bundle", str(bundle1100),
                 "--architecture", "gfx1100"],
                permission_env,
                expected=40,
            ))
            assert denied_write["error"]["code"] == "state_not_writable"
        finally:
            permission_base.chmod(0o700)
        cases += 1

        # 19. Concurrent preparation is rejected by the per-state lock.
        lock_env = manager_env(base / "locked")
        lock_state = Path(lock_env["CMFD_HIP_STATE_DIR"])
        lock_state.mkdir(parents=True)
        holder = subprocess.Popen(["flock", str(lock_state / "prepare.lock"), "sleep", "3"])
        time.sleep(0.2)
        try:
            locked = document(run(
                [manager, "prepare", "--bundle", str(bundle1100), "--architecture", "gfx1100"],
                lock_env,
                expected=34,
            ))
            assert locked["error"]["code"] == "preparation_in_progress"
        finally:
            holder.terminate()
            holder.wait(timeout=3)
        cases += 1

        # 20. Failed update leaves the last known-good active manifest untouched.
        rollback_manifest = (Path(update_env["CMFD_HIP_STATE_DIR"]) / "active.manifest").read_text()
        run(
            [manager, "prepare", "--bundle", str(bundle1036), "--sha256", "f" * 64,
             "--architecture", "gfx1036"],
            update_env,
            expected=27,
        )
        assert (Path(update_env["CMFD_HIP_STATE_DIR"]) / "active.manifest").read_text() == rollback_manifest
        cases += 1

        # 21. Worker wrapper selects exactly the active runtime libraries.
        fake_worker = base / "fake-worker"
        fake_worker.write_text(
            "#!/usr/bin/env bash\nprintf '%s\\n' \"$CMFD_HIP_RUNTIME_ROOT\" \"$LD_LIBRARY_PATH\"\n"
        )
        fake_worker.chmod(0o755)
        wrapper_env = dict(update_env)
        wrapper_env["CMFD_HIP_REPLAY_NATIVE"] = str(fake_worker)
        wrapper_env["CMFD_HIP_RUNTIME_MANAGER"] = manager
        wrapped = run([wrapper, "--self-test"], wrapper_env)
        lines = wrapped.stdout.splitlines()
        active_root = read_manifest_value_for_test(
            Path(update_env["CMFD_HIP_STATE_DIR"]) / "active.manifest", "runtime_root"
        )
        assert lines[0] == active_root and lines[1].startswith(active_root + "/lib:")
        cases += 1

        # 22. Launcher recovers once from a uniquely selected missing rocBLAS target.
        launcher_dir = base / "launcher"
        launcher_dir.mkdir()
        manager_log = launcher_dir / "manager.log"
        miner_log = launcher_dir / "miner.log"
        discovery_count = launcher_dir / "discovery.count"

        fake_manager = launcher_dir / "runtime-manager"
        fake_manager.write_text(
            "#!/usr/bin/env bash\n"
            f"printf '%s\\n' \"$*\" >> {str(manager_log)!r}\n"
            "printf '%s\\n' '{\"status\":\"ready\",\"error\":null}'\n"
        )
        fake_manager.chmod(0o755)

        fake_discovery = launcher_dir / "discovery"
        fake_discovery.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            f"count=0; [[ -r {str(discovery_count)!r} ]] && count=$(<{str(discovery_count)!r})\n"
            f"count=$((count + 1)); printf '%s\\n' \"$count\" > {str(discovery_count)!r}\n"
            "if ((count == 1)); then\n"
            "  printf '%s\\n' '{\"status\":\"error\",\"devices\":[{\"qualification\":\"rocblas_architecture_unavailable\",\"worker_selector\":\"pci:0000:0e:00.0\",\"architecture\":\"gfx1036\",\"integrated\":true}],\"selection\":null,\"error\":{\"code\":\"rocblas_architecture_unavailable\"}}'\n"
            "  exit 11\n"
            "fi\n"
            "printf '%s\\n' '{\"status\":\"ok\",\"devices\":[],\"selection\":{\"worker_selector\":\"pci:0000:0e:00.0\"},\"error\":null}'\n"
        )
        fake_discovery.chmod(0o755)

        fake_worker = launcher_dir / "worker"
        fake_worker.write_text("#!/usr/bin/env bash\nexit 0\n")
        fake_worker.chmod(0o755)
        fake_verifier = launcher_dir / "verifier"
        fake_verifier.write_text("#!/usr/bin/env bash\nexit 0\n")
        fake_verifier.chmod(0o755)
        fake_miner = launcher_dir / "miner"
        fake_miner.write_text(
            "#!/usr/bin/env bash\n"
            f"printf '%s\\n' \"$*\" > {str(miner_log)!r}\n"
        )
        fake_miner.chmod(0o755)
        fake_model = launcher_dir / "MODEL-V2.bank"
        fake_model.write_bytes(b"fixture")

        launcher_env = dict(os.environ)
        launcher_env.update({
            "CMFD_HIP_RUNTIME_MANAGER": str(fake_manager),
            "CMFD_HIP_DISCOVERY": str(fake_discovery),
            "CMFD_REPLAY_WORKER": str(fake_worker),
            "CMFD_TLS_VERIFIER": str(fake_verifier),
            "CMFD_MODEL_VERIFIER": str(fake_verifier),
            "CMFD_MINER_BINARY": str(fake_miner),
            "CMFD_MODEL_BANK": str(fake_model),
            "CMFD_SCRATCH_DIR": str(launcher_dir / "scratch"),
            "CMFD_SCREEN_LOG_DIR": str(launcher_dir / "logs"),
            "CMFD_PAYOUT_ADDRESS": "a" * 64,
            "CMFD_POOL_URL": "cmfd+tls://127.0.0.1:1?pin=" + "b" * 64,
            "CMFD_HIP_DEVICE_SELECTOR": "pci:0000:0e:00.0",
            "CMFD_HIP_ALLOW_INTEGRATED": "1",
            "CMFD_HIP_AUTHORIZE_DOWNLOAD": "1",
        })
        run([launcher], launcher_env)
        manager_calls = manager_log.read_text().splitlines()
        assert manager_calls == [
            "prepare --authorize-download",
            "prepare --architecture gfx1036 --authorize-download",
        ]
        assert discovery_count.read_text().strip() == "2"
        assert miner_log.read_text().startswith("pool --pool ")
        cases += 1

    assert cases == 22, cases
    print(f"CMFD_HIP_RUNTIME_MANAGER_TEST PASS cases={cases} network=simulated gpu=not-used")
    return 0


def read_manifest_value_for_test(path: Path, key: str) -> str:
    for line in path.read_text().splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1]
    raise AssertionError(f"missing {key} in {path}")


if __name__ == "__main__":
    raise SystemExit(main())
