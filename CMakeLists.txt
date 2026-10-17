cmake_minimum_required(VERSION 3.21)
project(cmfd_v4_hip_replay LANGUAGES CXX HIP)

include(CTest)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_HIP_STANDARD 20)
set(CMAKE_HIP_STANDARD_REQUIRED ON)

if(NOT DEFINED ROCM_ROOT)
  set(ROCM_ROOT "/opt/rocm/core-7.14")
endif()

# Build one portable worker containing the modern AMD targets accepted by the
# qualified ROCm toolchain.  Packagers may narrow or extend this list without
# editing the source.  Runtime eligibility is intentionally evaluated
# separately from code-object presence because rocBLAS packages can support a
# smaller architecture set than clang/HIP.
set(CMFD_HIP_ARCHITECTURES
  "gfx906;gfx908;gfx90a;gfx942;gfx1010;gfx1011;gfx1012;gfx1030;gfx1031;gfx1032;gfx1034;gfx1035;gfx1036;gfx1100;gfx1101;gfx1102;gfx1103;gfx1150;gfx1151;gfx1200;gfx1201"
  CACHE STRING "AMD GPU architectures embedded in the HIP worker")
set(CMFD_HIP_TESTED_ARCHITECTURES "gfx1036;gfx1100"
  CACHE STRING "Architectures physically qualified for Common Foundry")

string(REPLACE ";" "," CMFD_HIP_ARCHITECTURES_CSV
  "${CMFD_HIP_ARCHITECTURES}")
string(REPLACE ";" "," CMFD_HIP_TESTED_ARCHITECTURES_CSV
  "${CMFD_HIP_TESTED_ARCHITECTURES}")

message(STATUS "CMFD HIP code objects: ${CMFD_HIP_ARCHITECTURES}")
message(STATUS "CMFD physically tested architectures: ${CMFD_HIP_TESTED_ARCHITECTURES}")

add_library(cmfd-hip-discovery-core STATIC src/cmfd_hip_discovery.cpp)
target_include_directories(cmfd-hip-discovery-core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_include_directories(cmfd-hip-discovery-core SYSTEM PRIVATE
  "${ROCM_ROOT}/include")
target_compile_definitions(cmfd-hip-discovery-core PRIVATE __HIP_PLATFORM_AMD__=1)
target_compile_definitions(cmfd-hip-discovery-core PRIVATE
  CMFD_HIP_COMPILED_ARCHITECTURES="${CMFD_HIP_ARCHITECTURES_CSV}"
  CMFD_HIP_TESTED_ARCHITECTURES="${CMFD_HIP_TESTED_ARCHITECTURES_CSV}")
target_link_libraries(cmfd-hip-discovery-core PUBLIC ${CMAKE_DL_LIBS})
target_compile_options(cmfd-hip-discovery-core PRIVATE -O2 -Wall -Wextra -Wpedantic)

add_executable(cmfd-hip-discovery src/cmfd_hip_discovery_cli.cpp)
target_link_libraries(cmfd-hip-discovery PRIVATE cmfd-hip-discovery-core)
set_target_properties(cmfd-hip-discovery PROPERTIES
  OUTPUT_NAME "cmfd-hip-discovery-native"
  BUILD_RPATH "${ROCM_ROOT}/lib;${ROCM_ROOT}/lib/rocm_sysdeps/lib;${ROCM_ROOT}/lib/llvm/lib"
  INSTALL_RPATH "$ORIGIN/../lib;$ORIGIN/../lib/rocm_sysdeps/lib;$ORIGIN/../lib/llvm/lib"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

add_library(cmfd-hip-worker-protocol STATIC src/cmfd_hip_worker_protocol.cpp)
target_include_directories(cmfd-hip-worker-protocol PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_compile_options(cmfd-hip-worker-protocol PRIVATE -O2 -Wall -Wextra -Wpedantic)

add_executable(cmfd-v4-hip-replay src/cmfd_v4_hip_replay.hip)
set_source_files_properties(src/cmfd_v4_hip_replay.hip PROPERTIES LANGUAGE HIP)
target_include_directories(cmfd-v4-hip-replay PRIVATE "${ROCM_ROOT}/include")
target_link_directories(cmfd-v4-hip-replay PRIVATE "${ROCM_ROOT}/lib")
target_link_libraries(cmfd-v4-hip-replay PRIVATE
  cmfd-hip-discovery-core cmfd-hip-worker-protocol rocblas amdhip64)
target_compile_options(cmfd-v4-hip-replay PRIVATE
  $<$<COMPILE_LANGUAGE:HIP>:-O3 -Wall -Wextra -Wpedantic -Wno-deprecated-declarations>)
set_target_properties(cmfd-v4-hip-replay PROPERTIES
  HIP_ARCHITECTURES "${CMFD_HIP_ARCHITECTURES}"
  BUILD_RPATH "${ROCM_ROOT}/lib;${ROCM_ROOT}/lib/rocm_sysdeps/lib;${ROCM_ROOT}/lib/llvm/lib"
  INSTALL_RPATH "$ORIGIN/../lib;$ORIGIN/../lib/rocm_sysdeps/lib;$ORIGIN/../lib/llvm/lib"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

configure_file(runtime/cmfd-hip-discovery
  "${CMAKE_BINARY_DIR}/bin/cmfd-hip-discovery" COPYONLY)
configure_file(runtime/cmfd-hip-runtime
  "${CMAKE_BINARY_DIR}/bin/cmfd-hip-runtime" COPYONLY)
configure_file(runtime/packages-v1.tsv
  "${CMAKE_BINARY_DIR}/bin/packages-v1.tsv" COPYONLY)

install(TARGETS cmfd-v4-hip-replay cmfd-hip-discovery
  RUNTIME DESTINATION bin)
install(PROGRAMS
  cmfd-v4-hip-worker
  run-miner.sh
  runtime/cmfd-hip-discovery
  runtime/cmfd-hip-runtime
  tools/verify-model.sh
  tools/verify-pool-tls.sh
  tools/wsl-setup.sh
  DESTINATION bin)
install(PROGRAMS tools/nvidia-smi tools/cmfd-amd-screen tools/amd_gpu_telemetry.py
  DESTINATION libexec/common-foundry-amd-hip)
install(FILES runtime/packages-v1.tsv
  DESTINATION share/common-foundry/amd-hip)

if(BUILD_TESTING)
  add_executable(cmfd-hip-discovery-tests tests/discovery_tests.cpp)
  target_link_libraries(cmfd-hip-discovery-tests PRIVATE cmfd-hip-discovery-core)
  set_target_properties(cmfd-hip-discovery-tests PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests")
  add_test(NAME hip-discovery-fixtures COMMAND cmfd-hip-discovery-tests)

  add_executable(cmfd-hip-worker-protocol-tests tests/worker_protocol_tests.cpp)
  target_link_libraries(cmfd-hip-worker-protocol-tests PRIVATE cmfd-hip-worker-protocol)
  set_target_properties(cmfd-hip-worker-protocol-tests PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests")
  add_test(NAME hip-worker-protocol COMMAND cmfd-hip-worker-protocol-tests)

  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_Interpreter_FOUND)
    add_test(NAME hip-discovery-json
      COMMAND "${Python3_EXECUTABLE}"
              "${CMAKE_CURRENT_SOURCE_DIR}/tests/validate_discovery_json.py"
              "$<TARGET_FILE:cmfd-hip-discovery-tests>"
              "$<TARGET_FILE:cmfd-hip-discovery>")
    add_test(NAME hip-runtime-manager
      COMMAND "${Python3_EXECUTABLE}"
              "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_runtime_manager.py"
              "${CMAKE_CURRENT_SOURCE_DIR}/runtime/cmfd-hip-runtime"
              "${CMAKE_CURRENT_SOURCE_DIR}/cmfd-v4-hip-worker"
              "${CMAKE_CURRENT_SOURCE_DIR}/run-miner.sh")
    add_test(NAME amd-telemetry-and-screen
      COMMAND "${Python3_EXECUTABLE}"
              "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_amd_telemetry.py")
    add_test(NAME model-integrity-cache
      COMMAND "${Python3_EXECUTABLE}"
              "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_model_integrity_cache.py"
              "${CMAKE_CURRENT_SOURCE_DIR}/tools/verify-model.sh")
  endif()
endif()
