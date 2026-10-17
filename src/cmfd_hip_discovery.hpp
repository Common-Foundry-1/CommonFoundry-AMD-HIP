#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace cmfd_hip::discovery {

inline constexpr std::string_view kSchema = "common-foundry.amd-hip.discovery";
inline constexpr uint32_t kSchemaVersion = 1;
inline constexpr uint32_t kProductionBatchSize = 32;
inline constexpr uint64_t kProductionV4ModelAllocationBytes =
    384ULL * 4096 * 4096 + 128ULL * 4096 + 384ULL * 4096 * sizeof(int64_t);
inline constexpr uint64_t kProductionV4WorkspaceAllocationBytes =
    4ULL * 32 * 128 * 4096 * sizeof(int8_t)
    + 4ULL * 32 * 128 * 4096 * sizeof(int32_t)
    + 32ULL * 128 * 4096 * sizeof(uint32_t)
    + 32ULL * 385 * 20 * sizeof(uint8_t)
    + 32ULL * 385 * 128 * sizeof(uint16_t)
    + 32ULL * 385 * 4096 * sizeof(uint16_t);
inline constexpr uint64_t kProductionV4MemorySafetyMarginBytes =
    768ULL * 1024 * 1024;
inline constexpr uint64_t kMinimumProductionV4MemoryBytes =
    kProductionV4ModelAllocationBytes + kProductionV4WorkspaceAllocationBytes
    + kProductionV4MemorySafetyMarginBytes;
inline constexpr int kRequiredWorkgroupSize = 512;

struct RuntimeInfo {
    bool available = false;
    std::string root;
    std::string source;
    std::string version;
    std::string hip_library;
    std::string rocblas_library;
    std::string rocblas_library_directory;
    std::vector<std::string> rocblas_architectures;
    std::optional<std::string> error;
};

struct Device {
    int hip_index = -1;
    std::string name;
    std::string architecture;
    uint64_t vram_bytes = 0;
    std::optional<std::string> uuid;
    std::optional<std::string> pci_bus_id;
    std::optional<uint64_t> available_memory_bytes;
    std::optional<bool> integrated;
    int max_threads_per_block = 0;
    int warp_size = 0;
    int compute_units = 0;
};

struct Policy {
    bool allow_integrated = false;
};

struct Compatibility {
    bool architecture_compiled = false;
    bool rocblas_architecture_available = false;
    bool total_memory_sufficient = false;
    bool available_memory_sufficient = false;
    bool workgroup_supported = false;
    bool integrated_allowed = false;
    bool physically_tested = false;
    bool compatible = false;
    bool runtime_validation_required = true;
    std::string reason;
};

struct Error {
    std::string code;
    std::string message;
    int exit_code = 1;
};

struct Inventory {
    std::vector<Device> devices;
    std::optional<Error> error;
};

struct Selection {
    const Device* device = nullptr;
    std::optional<Error> error;
};

std::string base_architecture(std::string_view architecture);
std::vector<std::string> compiled_architectures();
std::vector<std::string> rocblas_architectures();
std::vector<std::string> physically_tested_architectures();
RuntimeInfo inspect_runtime();
Policy policy_from_environment();
Compatibility evaluate_device(const Device& device, const Policy& policy = {});
Compatibility evaluate_device(const Device& device, const Policy& policy,
                              const RuntimeInfo& runtime);
bool is_qualified(const Device& device, const Policy& policy = {});
bool is_qualified(const Device& device, const Policy& policy,
                  const RuntimeInfo& runtime);
std::optional<std::string> stable_id(const Device& device);
std::string worker_selector(const Device& device);

Inventory discover_devices();
Inventory discover_devices(const RuntimeInfo& runtime);
Selection select_device(const std::vector<Device>& devices,
                        const std::optional<std::string>& selector,
                        const Policy& policy = {});
Selection select_device(const std::vector<Device>& devices,
                        const std::optional<std::string>& selector,
                        const Policy& policy,
                        const RuntimeInfo& runtime);

std::string to_json(const Inventory& inventory,
                    const std::optional<Selection>& selection = std::nullopt,
                    const Policy& policy = {});
std::string to_json(const Inventory& inventory,
                    const std::optional<Selection>& selection,
                    const Policy& policy,
                    const RuntimeInfo& runtime);

}  // namespace cmfd_hip::discovery
