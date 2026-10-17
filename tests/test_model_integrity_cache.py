#!/usr/bin/env python3

import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def invoke(verifier: str, model: Path, cache: Path, digest: str) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    environment["CMFD_MODEL_CACHE_DIR"] = str(cache)
    return subprocess.run(
        [verifier, str(model), str(model.stat().st_size), digest],
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_model_integrity_cache.py VERIFIER")
    with tempfile.TemporaryDirectory(prefix="cmfd-model-cache-") as temporary:
        root = Path(temporary)
        model = root / "MODEL-V2.bank"
        cache = root / "cache"
        model.write_bytes(b"official-fixture")
        digest = hashlib.sha256(model.read_bytes()).hexdigest()

        first = invoke(sys.argv[1], model, cache, digest)
        assert first.returncode == 0 and "source=sha256" in first.stdout
        second = invoke(sys.argv[1], model, cache, digest)
        assert second.returncode == 0 and "source=cache" in second.stdout

        original_stat = model.stat()
        model.write_bytes(b"corrupt-fixture!")
        os.utime(model, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        corrupt_digest = hashlib.sha256(model.read_bytes()).hexdigest()
        rejected = invoke(sys.argv[1], model, cache, digest)
        assert rejected.returncode == 1 and corrupt_digest in rejected.stderr

    print("CMFD_MODEL_INTEGRITY_CACHE_TEST PASS cases=3")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
