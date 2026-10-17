# Third-party runtime and integration notices

The Common Foundry AMD HIP source and deployment helpers are distributed under
the adjacent MIT license. The official Common Foundry v1.0.13 reference source
is also MIT-licensed.

The small backend package produced by `package-linux.sh` does **not** embed an
AMD ROCm runtime, GPU driver, wallet, model bank or pool coordinator. On an
authorized first preparation, `cmfd-hip-runtime` can obtain an exact ROCm
7.14.0 artifact from AMD's official `repo.amd.com` or `repo.radeon.com`
origins. Those artifacts contain their own complete license directory and
notices, which must remain with the installed runtime and must be included by
any distributor that elects to redistribute the runtime instead of using the
first-run installer.

Principal runtime components used by this backend include:

| Component | Upstream license family | Role |
| --- | --- | --- |
| AMD HIP runtime | MIT | HIP host/runtime API and kernel launch |
| rocBLAS | MIT plus bundled third-party notices | exact INT8 GEMM |
| ROCR/HSA runtime | University of Illinois/NCSA | kernel/queue runtime |
| AMD COMGR / LLVM portions | Apache-2.0 with LLVM exceptions | code-object loading and support |
| hipBLASLt, rocRoller and runtime transitive components | licenses shipped by AMD in `share/doc` | transitive ROCm 7.14 dependencies |

The AMD GPU kernel driver is a system prerequisite and is never installed or
replaced silently by this project. The official runfile path installs only
ROCm user space into a private target; missing driver or operating-system
dependencies are reported as requiring explicit system authorization.

Release engineering must re-check the license inventory included in the exact
AMD artifact whenever the pinned ROCm release changes. This notice is an
inventory, not a substitute for the license texts shipped by AMD.
