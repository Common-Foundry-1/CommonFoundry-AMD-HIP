# Linux deployment and first-run contract

## Delivered architecture

The Linux contribution uses a hybrid distribution model:

1. A small reproducible Common Foundry package contains the prebuilt
   multi-architecture HIP worker, native discovery binary, launch wrappers,
   runtime manager, versioned AMD artifact catalog, integration scripts,
   sources, tests and documentation.
2. The 6.44 GB official `MODEL-V2.bank` is reused from the wallet. It is never
   duplicated by this package.
3. A coherent ROCm 7.14 ABI-family user-space runtime is selected locally. An existing
   compatible installation is adopted without changing it. Otherwise, after
   explicit user authorization, the manager downloads either the official AMD
   architecture-family tarball or the universal AMD runfile.
4. Downloaded user space is installed privately and atomically under the
   user's data directory. Drivers and operating-system packages are never
   silently installed or replaced.
5. The discovery and worker wrappers set a process-local library path to the
   selected runtime. They do not modify the wallet's global environment.

Linux is the supported product target because the worker and its deployment
path are qualified there, the official ROCm artifacts used here are Linux
artifacts, and the existing coordinator contract was validated on Linux.
This is a compatibility and evidence boundary. It is not a claim that HIP
Graphs or pinned memory are Linux-exclusive, or that Linux is faster than
another operating system.

## Runtime manager commands

All commands write exactly one final JSON document to stdout. Progress events
go to stderr, so they cannot corrupt the mining worker protocol.

```bash
cmfd-hip-runtime status
cmfd-hip-runtime prepare
cmfd-hip-runtime prepare --authorize-download
cmfd-hip-runtime prepare --architecture gfx1100 --authorize-download
cmfd-hip-runtime prepare --bundle /path/to/offline-runtime.tar.gz \
  --sha256 EXPECTED_SHA256 --architecture gfx1100
cmfd-hip-runtime verify
cmfd-hip-runtime verify --deep
cmfd-hip-runtime resolve
```

`prepare` first tries the already active runtime and then compatible system
locations. It returns `authorization_required` before any network access.
System installations outside the 7.14 ABI family are reported as incompatible
instead of being selected merely because similarly named libraries exist.
`--authorize-download` is the wallet's explicit record of user consent. When
HIP is unavailable and the exact architecture cannot be established safely,
the universal official runfile performs its own hardware detection. It is
invoked with a private target, user-space ROCm only, `nopostrocm`, and no
driver or dependency installation. Missing system prerequisites return
`system_authorization_required`; the manager never runs `sudo`.

When HIP already reports the exact target but rocBLAS lacks that target, the
wallet passes `--architecture gfx…` and the smaller official family tarball is
used. Names such as “RX 7900 XTX” are never used to guess an architecture.

## First launch example

On a Linux machine with an AMD display device but no usable HIP runtime:

1. `status` reports the AMD PCI identity with `architecture: null`, driver
   node/access state, `status: needs_preparation`, `network_required: true`
   and `authorization_required: true`.
2. The wallet explains the download size and asks the user once.
3. After consent, it calls `prepare --authorize-download`.
4. The manager takes a per-user lock, downloads from the pinned AMD HTTPS
   origin into a resumable `.part`, checks the exact catalogued size, computes
   SHA-256, validates the archive/installer, and extracts to a private staging
   directory.
5. It validates `libamdhip64`, `librocblas`, the rocBLAS architecture payload
   and version before atomically publishing `active.manifest`. A failed
   preparation leaves the previous manifest and runtime untouched.
6. The wallet calls `cmfd-hip-discovery --auto-select`. HIP now provides the
   real target, memory and capabilities. The worker runs its short exact
   cryptographic self-test before model loading.
7. If an otherwise eligible selected target lacks rocBLAS, the wallet performs
   one consent-gated `prepare --architecture gfx…` and repeats discovery. This
   is also how a later GPU change invalidates only the architecture-specific
   runtime choice.
8. The wallet launches `cmfd-v4-hip-worker --device-selector … --server …`.

No compiler, CMake, Git checkout, GitHub lookup or user benchmark participates
in that flow.

## Subsequent launch example

The wallet again calls `prepare` without download authorization. With an
unchanged installation it returns `status: ready` and `reused: true`. It does
not contact AMD, download, extract, reinstall or compile. Quick verification
checks the private manifest, critical library identity and the complete
rocBLAS filename/size/time inventory. Full SHA-256 of the two critical host
libraries is repeated only with `verify --deep` or after relevant metadata
changes.

The model verifier similarly caches a successful 6.44 GB model SHA-256 against
its canonical path, device/inode, size, nanosecond modification time and
nanosecond change time. Any replacement invalidates the cache and forces a
full hash. The cache never permits a wrong size or expected digest.

## Local state and atomicity

Defaults, with XDG variables honored:

- runtime state: `~/.local/share/common-foundry/amd-hip`;
- downloads: `STATE/downloads`;
- immutable private runtimes: `STATE/runtimes/VERSION-ARCH-SHA_PREFIX`;
- active pointer: `STATE/active.manifest`;
- last working pointer before a switch: `STATE/previous.manifest`;
- model cache: `~/.cache/common-foundry/amd-hip`.

The state directories are mode `700`, manifests/downloads are mode `600`, and
the process uses `umask 077`. A lock prevents simultaneous preparation. A
partial download is resumable; partial extraction is never selected. Global
ROCm directories are read but never overwritten.

## Runtime catalog and hardware boundary

The worker still contains these 21 compiler targets:

`gfx906 gfx908 gfx90a gfx942 gfx1010 gfx1011 gfx1012 gfx1030 gfx1031 gfx1032 gfx1034 gfx1035 gfx1036 gfx1100 gfx1101 gfx1102 gfx1103 gfx1150 gfx1151 gfx1200 gfx1201`

The ROCm 7.14.0 catalog supplies official AMD family artifacts for `gfx908`,
`gfx90a`, `gfx942`, `gfx1010`–`gfx1012`, `gfx1030`–`gfx1036`,
`gfx1100`–`gfx1103`, `gfx1150`, `gfx1151`, `gfx1200` and `gfx1201`.
`gfx906` remains present in the fat worker but has no ROCm 7.14 catalog entry
and is therefore not automatically prepared by this release.

This table separates facts that must not be conflated:

| Target group | Worker code object | ROCm 7.14 catalog | Local runtime test | Physical Common Foundry qualification |
| --- | --- | --- | --- | --- |
| `gfx1100` | yes | yes | yes | RX 7900 XTX: exact batch32 and real pool |
| `gfx1036` | yes | yes, `gfx103X-all` | yes: install, deep verify, self-test, exact batch32 | functional only; no pool/performance claim |
| Other catalogued targets | yes | yes | simulated discovery/deployment only | no |
| `gfx906` | yes | no | no | no |

Code-object or package presence is not physical qualification. The local
`gfx1036` result is exact but measured only 0.0887 effective FW/s, so it is not
a practical mining recommendation. Any other untested
target must still pass real HIP discovery, capability/memory checks, the exact
self-test and an exact batch32 check before a product owner upgrades its
support label.

## Memory policy

The former round 8 GiB free-memory rule has been replaced by a calculation
from the actual ProductionV4 batch32 allocations:

- resident model allocations: 6,455,558,144 bytes;
- persistent batch32 workspace: 506,978,944 bytes;
- safety/ROCm/graph allowance: 805,306,368 bytes;
- required free memory: 7,767,843,456 bytes.

This allows an otherwise capable 8 GiB device to be attempted when it truly
has enough free memory. Individual allocation failures remain fatal and
explicit. An integrated GPU additionally requires the same engine amount in
available system memory plus a 2 GiB operating-system reserve. Shared aperture
is not described as dedicated VRAM.

## Download authentication and integrity

`packages-v1.tsv` pins ROCm 7.14.0, exact official HTTPS URLs, content lengths
and, for S3 tarballs, immutable object version IDs. AMD's current tarball and
runfile directories do not publish adjacent SHA-256 or signature files. The
manager therefore computes SHA-256 on the first authenticated download and
records it for every resume/reuse; a product release may additionally pass a
publisher-computed `--sha256`, and offline bundles require that pin.

The AMD runfile also performs its embedded checksum validation. These checks
detect interruption, truncation and later cache corruption. They are not
misrepresented as an AMD detached signature. A distributor that requires an
independent pre-download digest must compute and sign its own release catalog
before publishing the wallet package.

Official references retained for release review:

- <https://rocm.docs.amd.com/en/docs-7.14.0/install/rocm.html>
- <https://rocm.docs.amd.com/en/docs-7.14.0/install/rocm-runfile-installer.html>
- <https://rocm.docs.amd.com/en/docs-7.14.0/compatibility/compatibility-matrix.html>
- <https://rocm.docs.amd.com/en/docs-7.14.0/about/release-notes.html>

## Supported systems and real evidence

The manager catalog follows AMD ROCm 7.14.0. AMD currently documents the
universal runfile for Ubuntu 22.04/24.04/26.04, selected RHEL 8/9/10, SLES
15.7/16, Debian 12/13, Oracle Linux 8/9/10 and Rocky 9.7. Actual GPU support
varies by OS and target and must be checked in AMD's matrix. The Common Foundry
backend itself has been physically tested only on Ubuntu 26.04.1, Linux
7.0.0, with the local qualified `gfx1100` system. Other distributions are
deployment candidates, not claims of local validation.

The system must expose an AMD `amdgpu` device, `/dev/kfd` and an accessible
`/dev/dri/render*`. Missing nodes, permissions, user-space runtime and rocBLAS
architecture payloads are separate error states.

## Founder integration sequence

The official wallet owner should call, in order:

1. `cmfd-hip-runtime status`.
2. If needed, display consent and call `prepare --authorize-download`.
3. `cmfd-hip-discovery --auto-select`, or `--list` plus an exact selector when
   several compatible dedicated devices exist.
4. `cmfd-v4-hip-worker --device-selector SELECTOR --server MODEL-V2.bank`.
5. Reuse the existing coordinator's rate, share, credit, block, connection and
   height accounting.
6. Send `QUIT` and retain existing child supervision on stop.

The wallet must add the HIP engine variant, package these executables, persist
an explicit selector when selection is ambiguous, show preparation progress,
and keep CUDA selection/fallback unchanged. The contribution does not modify
the official wallet automatically. AMD remains ProductionV4 pool-only.

## Reproducible backend package

```bash
./package-linux.sh /absolute/output/directory
```

The resulting tarball includes prebuilt binaries plus source, tests,
integration examples, a package manifest and `SHA256SUMS`. It excludes ROCm,
the model, wallet data, private logs and secrets. `SOURCE_DATE_EPOCH` can be
set by release automation; otherwise the current source commit timestamp is
used.

After extraction, verify the outer `.sha256` file and then the internal
manifest:

```bash
sha256sum -c common-foundry-amd-hip-v1.0.13-linux-x86_64.tar.gz.sha256
cd common-foundry-amd-hip-v1.0.13-linux-x86_64
sha256sum -c SHA256SUMS
bin/cmfd-hip-runtime status
```

The package deliberately does not redistribute the official coordinator or
6.44 GB model. Point the diagnostic/launcher at the authenticated v1.0.13
assets:

```bash
CMFD_MODEL_BANK=/absolute/path/to/MODEL-V2.bank \
  share/common-foundry/amd-hip/integration/07_TEST_AMD.sh --quick

CMFD_MINER_BINARY=/absolute/path/to/cmfd-miner \
CMFD_MODEL_BANK=/absolute/path/to/MODEL-V2.bank \
CMFD_PAYOUT_ADDRESS=<64-hex-public-address> \
CMFD_POOL_URL='cmfd+tls://NUMERIC_IP:PORT?pin=64_HEX' \
  share/common-foundry/amd-hip/integration/05_MINAGE_AMD_POOL.sh
```

The installed launchers find their sibling worker, manager, discovery,
verifiers and coordinator-compatibility probe without repository paths. No
historic pool endpoint is embedded.
