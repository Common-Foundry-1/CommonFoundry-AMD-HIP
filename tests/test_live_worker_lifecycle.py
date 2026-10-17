#!/usr/bin/env python3
"""Short, non-mining lifecycle checks for the real HIP worker executable."""

from __future__ import annotations

import argparse
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path


READY = "CMFD_V4_REPLAY_READY"


def worker_command(worker: Path, model: Path, selector: str | None) -> list[str]:
    command = [str(worker)]
    if selector:
        command.extend(["--device-selector", selector])
    command.extend(["--server", str(model)])
    return command


def start_worker(worker: Path, model: Path, selector: str | None) -> subprocess.Popen[str]:
    process = subprocess.Popen(
        worker_command(worker, model, selector),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    selector_io = selectors.DefaultSelector()
    selector_io.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            _, stderr = process.communicate()
            raise RuntimeError(f"worker exited before READY: rc={process.returncode}, stderr={stderr}")
        events = selector_io.select(timeout=0.25)
        if events:
            line = process.stdout.readline().rstrip("\r\n")
            if line == READY:
                selector_io.close()
                return process
            raise RuntimeError(f"unexpected worker stdout before READY: {line!r}")
    process.kill()
    _, stderr = process.communicate()
    raise RuntimeError(f"worker timed out before READY: stderr={stderr}")


def finish(process: subprocess.Popen[str], command: str | None = None) -> tuple[int, str, str]:
    if command is not None:
        assert process.stdin is not None
        process.stdin.write(command)
        process.stdin.flush()
    try:
        stdout, stderr = process.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        raise RuntimeError(f"worker did not terminate: stdout={stdout}, stderr={stderr}")
    return process.returncode, stdout, stderr


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("worker", type=Path)
    parser.add_argument("model", type=Path)
    parser.add_argument("--selector")
    arguments = parser.parse_args()

    if not arguments.worker.is_file() or not arguments.model.is_file():
        parser.error("worker and model must be existing files")

    normal = start_worker(arguments.worker, arguments.model, arguments.selector)
    normal_code, normal_stdout, normal_stderr = finish(normal, "EVICT\nQUIT\n")
    if (
        normal_code != 0
        or normal_stdout != "CMFD_V4_REPLAY_EVICTED\n"
        or "command=EVICT phase=done" not in normal_stderr
        or "CMFD_HIP_SERVER_EXIT reason=quit" not in normal_stderr
    ):
        raise RuntimeError(
            f"normal QUIT failed: rc={normal_code}, stdout={normal_stdout}, stderr={normal_stderr}"
        )

    failing = start_worker(arguments.worker, arguments.model, arguments.selector)
    error_code, error_stdout, error_stderr = finish(failing, "INVALID\n")
    if error_code != 1 or error_stdout or "CMFD_HIP_ERROR invalid persistent replay command" not in error_stderr:
        raise RuntimeError(
            f"protocol error failed: rc={error_code}, stdout={error_stdout}, stderr={error_stderr}"
        )

    supervised = start_worker(arguments.worker, arguments.model, arguments.selector)
    supervised.send_signal(signal.SIGINT)
    time.sleep(0.25)
    if supervised.poll() is not None:
        _, supervised_stderr = supervised.communicate()
        raise RuntimeError(
            "supervised SIGINT terminated worker before QUIT: "
            f"rc={supervised.returncode}, stderr={supervised_stderr}"
        )
    supervised_code, supervised_stdout, supervised_stderr = finish(supervised, "QUIT\n")
    if (
        supervised_code != 0
        or supervised_stdout
        or "signal=SIGINT number=2 action=deferred_to_supervisor" not in supervised_stderr
        or "CMFD_HIP_SERVER_EXIT reason=quit" not in supervised_stderr
    ):
        raise RuntimeError(
            "supervised SIGINT failed: "
            f"rc={supervised_code}, stdout={supervised_stdout}, stderr={supervised_stderr}"
        )

    interrupted = start_worker(arguments.worker, arguments.model, arguments.selector)
    interrupted.send_signal(signal.SIGTERM)
    interrupt_code, interrupt_stdout, interrupt_stderr = finish(interrupted)
    if interrupt_code != 143 or interrupt_stdout or "CMFD_HIP_SIGNAL signal=SIGTERM number=15" not in interrupt_stderr:
        raise RuntimeError(
            "signal diagnostic failed: "
            f"rc={interrupt_code}, stdout={interrupt_stdout}, stderr={interrupt_stderr}"
        )

    print(
        "CMFD_HIP_WORKER_LIFECYCLE_TEST PASS "
        "normal=0 error=1 supervised_sigint=0 interrupt=143"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"CMFD_HIP_WORKER_LIFECYCLE_TEST FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
