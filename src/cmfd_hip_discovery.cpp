#include "cmfd_hip_discovery.hpp"

#include <hip/hip_runtime_api.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <utility>

#ifndef CMFD_HIP_COMPILED_ARCHITECTURES
#define CMFD_HIP_COMPILED_ARCHITECTURES "gfx1100"
#endif
#ifndef CMFD_HIP_TESTED_ARCHITECTURES
#define CMFD_HIP_TESTED_ARCHITECTURES "gfx1036,gfx1100"
#endif

namespace cmfd_hip::discovery {
namespace {

namespace fs = std::filesystem;

Error make_error(std::string code, std::string message, int exit_code) {
    return Error{std::move(code), std::move(message), exit_code};
}

std::string lower_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

std::vector<std::string> split_architectures(std::string_view csv) {
    std::vector<std::string> result;
    size_t begin = 0;
    while (begin <= csv.size()) {
        const size_t end = csv.find(',', begin);
        const std::string value = lower_ascii(std::string(csv.substr(
            begin, end == std::string_view::npos ? csv.size() - begin : end - begin)));
        if (!value.empty() && std::find(result.begin(), result.end(), value) == result.end())
            result.push_back(value);
        if (end == std::string_view::npos) break;
        begin = end + 1;
    }
    std::sort(result.begin(), result.end());
    return result;
}

bool contains_architecture(const std::vector<std::string>& values,
                           std::string_view architecture) {
    return std::find(values.begin(), values.end(), architecture) != values.end();
}

std::string trim_ascii(std::string value) {
    while (!value.empty() && std::isspace(static_cast<unsigned char>(value.back())))
        value.pop_back();
    size_t begin = 0;
    while (begin < value.size()
           && std::isspace(static_cast<unsigned char>(value[begin])))
        ++begin;
    return value.substr(begin);
}

std::string read_runtime_version(const fs::path& root) {
    {
        std::ifstream input(root / ".info" / "version");
        std::string line;
        while (input && std::getline(input, line)) {
            line = trim_ascii(line);
            if (!line.empty() && line.front() != '#') return line;
        }
    }
    std::ifstream input(root / "share" / "hip" / "version");
    std::string major;
    std::string minor;
    std::string patch;
    std::string line;
    while (input && std::getline(input, line)) {
        const size_t separator = line.find('=');
        if (separator == std::string::npos) continue;
        const std::string key = trim_ascii(line.substr(0, separator));
        const std::string value = trim_ascii(line.substr(separator + 1));
        if (key == "HIP_VERSION_MAJOR") major = value;
        else if (key == "HIP_VERSION_MINOR") minor = value;
        else if (key == "HIP_VERSION_PATCH") patch = value;
    }
    if (major.empty() || minor.empty()) return "unknown";
    return major + "." + minor + (patch.empty() ? "" : "." + patch);
}

bool compatible_runtime_version(std::string_view version) {
    return version == "7.14" || version.starts_with("7.14.");
}

std::optional<fs::path> find_library(const fs::path& directory,
                                     std::string_view unversioned,
                                     std::string_view versioned_prefix) {
    std::error_code error;
    const fs::path direct = directory / unversioned;
    if (fs::exists(direct, error)) return direct;
    if (!fs::is_directory(directory, error)) return std::nullopt;
    std::vector<fs::path> matches;
    for (fs::directory_iterator iterator(directory, error), end;
         !error && iterator != end; iterator.increment(error)) {
        const std::string name = iterator->path().filename().string();
        if (name.starts_with(versioned_prefix)) matches.push_back(iterator->path());
    }
    if (matches.empty()) return std::nullopt;
    std::sort(matches.begin(), matches.end());
    return matches.back();
}

std::vector<std::string> scan_rocblas_architectures(const fs::path& directory) {
    std::set<std::string> architectures;
    std::error_code error;
    if (!fs::is_directory(directory, error)) return {};
    for (fs::directory_iterator iterator(directory, error), end;
         !error && iterator != end; iterator.increment(error)) {
        const std::string name = lower_ascii(iterator->path().filename().string());
        size_t offset = 0;
        while ((offset = name.find("gfx", offset)) != std::string::npos) {
            size_t finish = offset + 3;
            while (finish < name.size()
                   && std::isxdigit(static_cast<unsigned char>(name[finish])) != 0)
                ++finish;
            if (finish > offset + 3)
                architectures.insert(name.substr(offset, finish - offset));
            offset = finish;
        }
    }
    return {architectures.begin(), architectures.end()};
}

RuntimeInfo inspect_runtime_root(const fs::path& requested_root,
                                 std::string source) {
    RuntimeInfo runtime;
    runtime.source = std::move(source);
    std::error_code error;
    fs::path root = fs::weakly_canonical(requested_root, error);
    if (error) root = requested_root.lexically_normal();
    runtime.root = root.string();
    if (!root.is_absolute()) {
        runtime.error = "ROCm runtime root must be an absolute path";
        return runtime;
    }

    const fs::path library_directory = root / "lib";
    const auto hip_library = find_library(
        library_directory, "libamdhip64.so", "libamdhip64.so.");
    const auto rocblas_library = find_library(
        library_directory, "librocblas.so", "librocblas.so.");
    const fs::path rocblas_directory = library_directory / "rocblas" / "library";
    if (hip_library) runtime.hip_library = hip_library->string();
    if (rocblas_library) runtime.rocblas_library = rocblas_library->string();
    runtime.rocblas_library_directory = rocblas_directory.string();
    runtime.rocblas_architectures = scan_rocblas_architectures(rocblas_directory);
    runtime.version = read_runtime_version(root);

    if (!hip_library) runtime.error = "libamdhip64 is missing from " + library_directory.string();
    else if (!rocblas_library)
        runtime.error = "librocblas is missing from " + library_directory.string();
    else if (runtime.rocblas_architectures.empty())
        runtime.error = "rocBLAS has no architecture code objects in "
            + rocblas_directory.string();
    else if (!compatible_runtime_version(runtime.version))
        runtime.error = "ROCm runtime " + runtime.version
            + " is incompatible; this worker requires the 7.14 ABI family";
    else
        runtime.available = true;
    return runtime;
}

std::optional<fs::path> manifest_runtime_root(const fs::path& manifest,
                                              std::string& error_message) {
    std::ifstream input(manifest);
    if (!input) {
        error_message = "cannot read runtime manifest " + manifest.string();
        return std::nullopt;
    }
    std::string schema;
    std::string complete;
    std::string root;
    std::string line;
    while (std::getline(input, line)) {
        if (line.empty() || line.front() == '#') continue;
        const size_t separator = line.find('=');
        if (separator == std::string::npos) continue;
        const std::string key = trim_ascii(line.substr(0, separator));
        const std::string value = trim_ascii(line.substr(separator + 1));
        if (key == "schema") schema = value;
        else if (key == "complete") complete = value;
        else if (key == "runtime_root") root = value;
    }
    if (schema != "common-foundry.amd-hip.runtime-v1" || complete != "1"
        || root.empty()) {
        error_message = "runtime manifest is incomplete or has an unsupported schema";
        return std::nullopt;
    }
    const fs::path result(root);
    if (!result.is_absolute()) {
        error_message = "runtime manifest root is not absolute";
        return std::nullopt;
    }
    return result;
}

fs::path default_runtime_manifest_path() {
    if (const char* state = std::getenv("CMFD_HIP_STATE_DIR"); state && state[0] != '\0')
        return fs::path(state) / "active.manifest";
    if (const char* data = std::getenv("XDG_DATA_HOME"); data && data[0] != '\0')
        return fs::path(data) / "common-foundry" / "amd-hip" / "active.manifest";
    if (const char* home = std::getenv("HOME"); home && home[0] != '\0')
        return fs::path(home) / ".local" / "share" / "common-foundry"
            / "amd-hip" / "active.manifest";
    return {};
}

RuntimeInfo unavailable_runtime(std::string source, std::string message) {
    RuntimeInfo runtime;
    runtime.source = std::move(source);
    runtime.error = std::move(message);
    return runtime;
}

std::string bounded_string(const char* value, size_t capacity) {
    return std::string(value, strnlen(value, capacity));
}

bool uuid_has_value(const hipUUID& uuid) {
    return std::any_of(std::begin(uuid.bytes), std::end(uuid.bytes),
                       [](char byte) { return byte != 0; });
}

std::optional<std::string> format_uuid(const hipUUID& uuid) {
    const size_t text_length = strnlen(uuid.bytes, sizeof(uuid.bytes));
    const std::string token(uuid.bytes, text_length);
    if (token == "XX") return std::nullopt;
    if (text_length == sizeof(uuid.bytes)
        && std::all_of(token.begin(), token.end(), [](unsigned char character) {
               return std::isxdigit(character) != 0;
           }))
        return "GPU-" + lower_ascii(token);

    static constexpr std::array<size_t, 4> kSeparators = {4, 6, 8, 10};
    std::ostringstream output;
    output << std::hex << std::setfill('0');
    for (size_t index = 0; index < sizeof(uuid.bytes); ++index) {
        if (std::find(kSeparators.begin(), kSeparators.end(), index) != kSeparators.end())
            output << '-';
        output << std::setw(2)
               << static_cast<unsigned int>(static_cast<unsigned char>(uuid.bytes[index]));
    }
    return output.str();
}

std::string json_escape(std::string_view value) {
    std::ostringstream output;
    for (const unsigned char character : value) {
        switch (character) {
            case '"': output << "\\\""; break;
            case '\\': output << "\\\\"; break;
            case '\b': output << "\\b"; break;
            case '\f': output << "\\f"; break;
            case '\n': output << "\\n"; break;
            case '\r': output << "\\r"; break;
            case '\t': output << "\\t"; break;
            default:
                if (character < 0x20) {
                    output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                           << static_cast<unsigned int>(character) << std::dec;
                } else {
                    output << static_cast<char>(character);
                }
        }
    }
    return output.str();
}

void write_nullable_string(std::ostringstream& output,
                           const std::optional<std::string>& value) {
    if (value) output << '"' << json_escape(*value) << '"';
    else output << "null";
}

void write_nullable_uint64(std::ostringstream& output,
                           const std::optional<uint64_t>& value) {
    if (value) output << *value;
    else output << "null";
}

void write_nullable_bool(std::ostringstream& output,
                         const std::optional<bool>& value) {
    if (value) output << (*value ? "true" : "false");
    else output << "null";
}

void write_string_array(std::ostringstream& output,
                        const std::vector<std::string>& values) {
    output << '[';
    for (size_t index = 0; index < values.size(); ++index) {
        if (index != 0) output << ',';
        output << '"' << json_escape(values[index]) << '"';
    }
    output << ']';
}

void write_error(std::ostringstream& output, const std::optional<Error>& error) {
    if (!error) {
        output << "null";
        return;
    }
    output << "{\"code\":\"" << json_escape(error->code)
           << "\",\"message\":\"" << json_escape(error->message) << "\"}";
}

class DynamicHip {
  public:
    using GetDeviceCount = hipError_t (*)(int*);
    using GetDeviceProperties = hipError_t (*)(hipDeviceProp_t*, int);
    using DeviceGetUuid = hipError_t (*)(hipUUID*, hipDevice_t);
    using DeviceGetPciBusId = hipError_t (*)(char*, int, int);
    using GetDevice = hipError_t (*)(int*);
    using SetDevice = hipError_t (*)(int);
    using MemGetInfo = hipError_t (*)(size_t*, size_t*);
    using GetErrorString = const char* (*)(hipError_t);

    explicit DynamicHip(const RuntimeInfo& runtime)
        : handle_(dlopen(runtime.hip_library.empty() ? "libamdhip64.so"
                                                     : runtime.hip_library.c_str(),
                         RTLD_NOW | RTLD_LOCAL),
                  &dlclose) {
        if (!handle_) {
            const char* detail = dlerror();
            error_ = detail ? detail : "dynamic loader returned no detail";
            return;
        }
        get_device_count = symbol<GetDeviceCount>("hipGetDeviceCount");
        get_device_properties = symbol<GetDeviceProperties>("hipGetDevicePropertiesR0600");
        device_get_uuid = symbol<DeviceGetUuid>("hipDeviceGetUuid", false);
        device_get_pci_bus_id = symbol<DeviceGetPciBusId>("hipDeviceGetPCIBusId", false);
        get_device = symbol<GetDevice>("hipGetDevice", false);
        set_device = symbol<SetDevice>("hipSetDevice", false);
        mem_get_info = symbol<MemGetInfo>("hipMemGetInfo", false);
        get_error_string = symbol<GetErrorString>("hipGetErrorString", false);
    }

    bool available() const {
        return handle_ && get_device_count && get_device_properties;
    }

    const std::string& error() const { return error_; }

    std::string describe(hipError_t status) const {
        if (get_error_string) {
            if (const char* text = get_error_string(status)) return text;
        }
        return "HIP status " + std::to_string(static_cast<int>(status));
    }

    GetDeviceCount get_device_count = nullptr;
    GetDeviceProperties get_device_properties = nullptr;
    DeviceGetUuid device_get_uuid = nullptr;
    DeviceGetPciBusId device_get_pci_bus_id = nullptr;
    GetDevice get_device = nullptr;
    SetDevice set_device = nullptr;
    MemGetInfo mem_get_info = nullptr;
    GetErrorString get_error_string = nullptr;

  private:
    template <typename Function>
    Function symbol(const char* name, bool required = true) {
        dlerror();
        void* address = dlsym(handle_.get(), name);
        if (const char* detail = dlerror()) {
            if (required && error_.empty()) error_ = std::string(name) + ": " + detail;
            return nullptr;
        }
        return reinterpret_cast<Function>(address);
    }

    std::unique_ptr<void, int (*)(void*)> handle_{nullptr, &dlclose};
    std::string error_;
};

bool selector_is_index(std::string_view selector, int& index) {
    constexpr std::string_view prefix = "hip:";
    if (!selector.starts_with(prefix) || selector.size() == prefix.size()) return false;
    const std::string_view digits = selector.substr(prefix.size());
    if (!std::all_of(digits.begin(), digits.end(),
                     [](unsigned char value) { return std::isdigit(value) != 0; }))
        return false;
    try {
        size_t consumed = 0;
        const int parsed = std::stoi(std::string(digits), &consumed);
        if (consumed != digits.size() || parsed < 0) return false;
        index = parsed;
        return true;
    } catch (...) {
        return false;
    }
}

bool selector_is_stable(std::string_view selector) {
    if (selector.starts_with("uuid:")) {
        const std::string_view value = selector.substr(5);
        if (value.starts_with("gpu-") && value.size() == 20)
            return std::all_of(value.begin() + 4, value.end(), [](unsigned char character) {
                return std::isxdigit(character) != 0;
            });
        if (value.size() != 36) return false;
        for (size_t index = 0; index < value.size(); ++index) {
            if (index == 8 || index == 13 || index == 18 || index == 23) {
                if (value[index] != '-') return false;
            } else if (std::isxdigit(static_cast<unsigned char>(value[index])) == 0) {
                return false;
            }
        }
        return true;
    }
    if (selector.starts_with("pci:")) {
        const std::string_view value = selector.substr(4);
        if (value.size() != 12 || value[4] != ':' || value[7] != ':' || value[10] != '.')
            return false;
        for (size_t index = 0; index < value.size(); ++index) {
            if (index == 4 || index == 7 || index == 10) continue;
            if (std::isxdigit(static_cast<unsigned char>(value[index])) == 0) return false;
        }
        return true;
    }
    return false;
}

Error compatibility_error(const Device& device, const Compatibility& compatibility) {
    const std::string architecture = base_architecture(device.architecture);
    if (compatibility.reason == "architecture_not_compiled")
        return make_error("architecture_not_compiled",
                          "Selected AMD HIP architecture " + architecture
                              + " is not embedded in this worker build", 8);
    if (compatibility.reason == "rocblas_architecture_unavailable")
        return make_error("rocblas_architecture_unavailable",
                          "The packaged rocBLAS library has no code objects for " + architecture,
                          11);
    if (compatibility.reason == "insufficient_total_memory"
        || compatibility.reason == "insufficient_available_memory")
        return make_error("insufficient_memory",
                          "Selected AMD HIP device does not have the required "
                              + std::to_string(kMinimumProductionV4MemoryBytes)
                              + " bytes available for ProductionV4 batch 32",
                          12);
    if (compatibility.reason == "workgroup_not_supported")
        return make_error("capability_not_supported",
                          "Selected AMD HIP device cannot run the required 512-thread workgroups",
                          13);
    if (compatibility.reason == "integrated_device_disabled")
        return make_error("integrated_device_disabled",
                          "Selected integrated AMD GPU is disabled by policy; set CMFD_HIP_ALLOW_INTEGRATED=1 to opt in",
                          10);
    if (compatibility.reason == "integrated_status_unknown")
        return make_error("integrated_status_unknown",
                          "HIP could not determine whether the selected GPU is integrated; explicitly opt in with CMFD_HIP_ALLOW_INTEGRATED=1",
                          10);
    return make_error("device_not_compatible",
                      "Selected AMD HIP device is not compatible with ProductionV4", 8);
}

}  // namespace

std::string base_architecture(std::string_view architecture) {
    const size_t feature_separator = architecture.find(':');
    return lower_ascii(std::string(architecture.substr(0, feature_separator)));
}

std::vector<std::string> compiled_architectures() {
    return split_architectures(CMFD_HIP_COMPILED_ARCHITECTURES);
}

std::vector<std::string> rocblas_architectures() {
    return inspect_runtime().rocblas_architectures;
}

std::vector<std::string> physically_tested_architectures() {
    return split_architectures(CMFD_HIP_TESTED_ARCHITECTURES);
}

RuntimeInfo inspect_runtime() {
    if (const char* root = std::getenv("CMFD_HIP_RUNTIME_ROOT"); root && root[0] != '\0')
        return inspect_runtime_root(root, "environment");

    const char* manifest_environment = std::getenv("CMFD_HIP_RUNTIME_MANIFEST");
    fs::path manifest = manifest_environment && manifest_environment[0] != '\0'
        ? fs::path(manifest_environment) : default_runtime_manifest_path();
    std::error_code error;
    if (!manifest.empty() && fs::exists(manifest, error)) {
        std::string manifest_error;
        const auto root = manifest_runtime_root(manifest, manifest_error);
        if (!root) return unavailable_runtime("manifest", manifest_error);
        RuntimeInfo runtime = inspect_runtime_root(*root, "manifest");
        if (runtime.error)
            runtime.error = "active runtime manifest is not usable: " + *runtime.error;
        return runtime;
    }
    if (manifest_environment && manifest_environment[0] != '\0')
        return unavailable_runtime("manifest", "explicit runtime manifest does not exist");

    std::vector<fs::path> candidates;
    const fs::path opt_rocm("/opt/rocm");
    if (fs::exists(opt_rocm, error)) candidates.push_back(opt_rocm);
    error.clear();
    if (fs::is_directory(opt_rocm, error)) {
        for (fs::directory_iterator iterator(opt_rocm, error), end;
             !error && iterator != end; iterator.increment(error)) {
            if (iterator->path().filename().string().starts_with("core-"))
                candidates.push_back(iterator->path());
        }
    }
    error.clear();
    const fs::path opt("/opt");
    if (fs::is_directory(opt, error)) {
        for (fs::directory_iterator iterator(opt, error), end;
             !error && iterator != end; iterator.increment(error)) {
            const std::string name = iterator->path().filename().string();
            if (name.starts_with("rocm-") && fs::is_directory(iterator->path(), error))
                candidates.push_back(iterator->path());
        }
    }

    std::set<std::string> seen;
    std::vector<RuntimeInfo> usable;
    std::optional<RuntimeInfo> first_invalid;
    for (const fs::path& candidate : candidates) {
        error.clear();
        fs::path canonical = fs::weakly_canonical(candidate, error);
        if (error) canonical = candidate.lexically_normal();
        if (!seen.insert(canonical.string()).second) continue;
        RuntimeInfo runtime = inspect_runtime_root(canonical, "system");
        if (runtime.available) usable.push_back(std::move(runtime));
        else if (!first_invalid) first_invalid = std::move(runtime);
    }
    if (!usable.empty()) {
        std::sort(usable.begin(), usable.end(), [](const RuntimeInfo& left,
                                                   const RuntimeInfo& right) {
            if (left.version != right.version) return left.version > right.version;
            return left.root > right.root;
        });
        return usable.front();
    }
    if (first_invalid) return *first_invalid;
    return unavailable_runtime(
        "none",
        "no coherent ROCm runtime was found; run cmfd-hip-runtime prepare first");
}

Policy policy_from_environment() {
    const char* value = std::getenv("CMFD_HIP_ALLOW_INTEGRATED");
    if (!value || value[0] == '\0' || std::string_view(value) == "0") return {};
    if (std::string_view(value) == "1") return Policy{true};
    throw std::invalid_argument("CMFD_HIP_ALLOW_INTEGRATED must be 0 or 1");
}

Compatibility evaluate_device(const Device& device, const Policy& policy) {
    return evaluate_device(device, policy, inspect_runtime());
}

Compatibility evaluate_device(const Device& device, const Policy& policy,
                              const RuntimeInfo& runtime) {
    const std::string architecture = base_architecture(device.architecture);
    Compatibility result;
    result.architecture_compiled = contains_architecture(compiled_architectures(), architecture);
    result.rocblas_architecture_available = runtime.available
        && contains_architecture(runtime.rocblas_architectures, architecture);
    result.total_memory_sufficient = device.vram_bytes >= kMinimumProductionV4MemoryBytes;
    result.available_memory_sufficient = !device.available_memory_bytes
        || *device.available_memory_bytes >= kMinimumProductionV4MemoryBytes;
    result.workgroup_supported = device.max_threads_per_block >= kRequiredWorkgroupSize;
    result.integrated_allowed = device.integrated == false
        || (policy.allow_integrated && (!device.integrated || *device.integrated));
    result.physically_tested = contains_architecture(physically_tested_architectures(), architecture);
    result.runtime_validation_required = !result.physically_tested;

    if (!result.architecture_compiled) result.reason = "architecture_not_compiled";
    else if (!device.integrated && !policy.allow_integrated)
        result.reason = "integrated_status_unknown";
    else if (device.integrated == true && !policy.allow_integrated)
        result.reason = "integrated_device_disabled";
    else if (!result.rocblas_architecture_available)
        result.reason = "rocblas_architecture_unavailable";
    else if (!result.total_memory_sufficient) result.reason = "insufficient_total_memory";
    else if (!result.available_memory_sufficient) result.reason = "insufficient_available_memory";
    else if (!result.workgroup_supported) result.reason = "workgroup_not_supported";
    else {
        result.compatible = true;
        result.reason = result.physically_tested ? "qualified" : "runtime_validation_required";
    }
    return result;
}

bool is_qualified(const Device& device, const Policy& policy) {
    return evaluate_device(device, policy).compatible;
}

bool is_qualified(const Device& device, const Policy& policy,
                  const RuntimeInfo& runtime) {
    return evaluate_device(device, policy, runtime).compatible;
}

std::optional<std::string> stable_id(const Device& device) {
    if (device.uuid && !device.uuid->empty()) return "uuid:" + lower_ascii(*device.uuid);
    if (device.pci_bus_id && !device.pci_bus_id->empty())
        return "pci:" + lower_ascii(*device.pci_bus_id);
    return std::nullopt;
}

std::string worker_selector(const Device& device) {
    if (const auto identifier = stable_id(device)) return *identifier;
    return "hip:" + std::to_string(device.hip_index);
}

Inventory discover_devices() {
    return discover_devices(inspect_runtime());
}

Inventory discover_devices(const RuntimeInfo& runtime) {
    if (!runtime.available) {
        return {{}, make_error(
            "hip_runtime_unavailable",
            "AMD HIP runtime is unavailable: "
                + runtime.error.value_or("runtime validation failed"), 3)};
    }
    DynamicHip hip(runtime);
    if (!hip.available()) {
        return {{}, make_error("hip_runtime_unavailable",
                               "AMD HIP runtime is unavailable: " + hip.error(), 3)};
    }

    int count = 0;
    const hipError_t count_status = hip.get_device_count(&count);
    if (count_status != hipSuccess) {
        return {{}, make_error("hip_discovery_failed",
                               "hipGetDeviceCount failed: " + hip.describe(count_status), 4)};
    }
    if (count < 0) {
        return {{}, make_error("hip_discovery_failed",
                               "hipGetDeviceCount returned a negative device count", 4)};
    }

    int original_device = -1;
    const bool can_query_memory = hip.get_device && hip.set_device && hip.mem_get_info;
    const bool have_original_device = can_query_memory
        && hip.get_device(&original_device) == hipSuccess;

    Inventory inventory;
    inventory.devices.reserve(static_cast<size_t>(count));
    for (int index = 0; index < count; ++index) {
        hipDeviceProp_t properties{};
        const hipError_t properties_status = hip.get_device_properties(&properties, index);
        if (properties_status != hipSuccess) {
            return {{}, make_error(
                "hip_discovery_failed",
                "hipGetDeviceProperties failed for HIP device " + std::to_string(index)
                    + ": " + hip.describe(properties_status), 4)};
        }

        Device device;
        device.hip_index = index;
        device.name = bounded_string(properties.name, sizeof(properties.name));
        device.architecture = bounded_string(properties.gcnArchName,
                                             sizeof(properties.gcnArchName));
        device.vram_bytes = static_cast<uint64_t>(properties.totalGlobalMem);
        device.integrated = properties.integrated != 0;
        device.max_threads_per_block = properties.maxThreadsPerBlock;
        device.warp_size = properties.warpSize;
        device.compute_units = properties.multiProcessorCount;

        if (can_query_memory && hip.set_device(index) == hipSuccess) {
            size_t free_bytes = 0;
            size_t total_bytes = 0;
            if (hip.mem_get_info(&free_bytes, &total_bytes) == hipSuccess)
                device.available_memory_bytes = static_cast<uint64_t>(free_bytes);
        }

        hipUUID uuid = properties.uuid;
        if (hip.device_get_uuid) {
            hipUUID queried{};
            if (hip.device_get_uuid(&queried, index) == hipSuccess && uuid_has_value(queried))
                uuid = queried;
        }
        if (uuid_has_value(uuid)) device.uuid = format_uuid(uuid);

        if (hip.device_get_pci_bus_id) {
            std::array<char, 32> pci{};
            if (hip.device_get_pci_bus_id(pci.data(), static_cast<int>(pci.size()), index)
                    == hipSuccess
                && pci.front() != '\0')
                device.pci_bus_id = lower_ascii(bounded_string(pci.data(), pci.size()));
        }
        inventory.devices.push_back(std::move(device));
    }
    if (have_original_device) (void)hip.set_device(original_device);
    return inventory;
}

Selection select_device(const std::vector<Device>& devices,
                        const std::optional<std::string>& selector,
                        const Policy& policy) {
    return select_device(devices, selector, policy, inspect_runtime());
}

Selection select_device(const std::vector<Device>& devices,
                        const std::optional<std::string>& selector,
                        const Policy& policy,
                        const RuntimeInfo& runtime) {
    std::vector<const Device*> matches;
    if (!selector) {
        for (const Device& device : devices)
            if (is_qualified(device, policy, runtime)) matches.push_back(&device);
        if (matches.empty()) {
            return {nullptr, make_error("no_qualified_device",
                                        "No compatible AMD HIP device is available under the current policy", 7)};
        }
        if (matches.size() > 1) {
            std::vector<const Device*> dedicated;
            for (const Device* device : matches)
                if (device->integrated && !*device->integrated)
                    dedicated.push_back(device);
            if (dedicated.size() == 1) return {dedicated.front(), std::nullopt};
            return {nullptr, make_error(
                "ambiguous_selector",
                dedicated.size() > 1
                    ? "Multiple compatible dedicated AMD HIP devices are available; select one explicitly"
                    : "Multiple compatible AMD HIP devices are available and no unique dedicated device can be preferred; select one explicitly",
                6)};
        }
    } else {
        int hip_index = -1;
        const std::string normalized = lower_ascii(*selector);
        if (selector_is_index(normalized, hip_index)) {
            for (const Device& device : devices)
                if (device.hip_index == hip_index) matches.push_back(&device);
        } else if (selector_is_stable(normalized)) {
            for (const Device& device : devices) {
                const bool uuid_match = device.uuid
                    && "uuid:" + lower_ascii(*device.uuid) == normalized;
                const bool pci_match = device.pci_bus_id
                    && "pci:" + lower_ascii(*device.pci_bus_id) == normalized;
                if (uuid_match || pci_match) matches.push_back(&device);
            }
        } else {
            return {nullptr, make_error(
                "invalid_selector",
                "Device selector must be hip:<index>, uuid:<uuid>, or pci:<bus-id>", 5)};
        }
        if (matches.empty()) {
            return {nullptr, make_error("device_not_found",
                                        "No AMD HIP device matches the requested selector", 9)};
        }
        if (matches.size() > 1) {
            return {nullptr, make_error("ambiguous_selector",
                                        "The requested selector matches multiple HIP devices", 6)};
        }
    }

    const Compatibility compatibility = evaluate_device(*matches.front(), policy, runtime);
    if (!compatibility.compatible)
        return {nullptr, compatibility_error(*matches.front(), compatibility)};
    return {matches.front(), std::nullopt};
}

std::string to_json(const Inventory& inventory,
                    const std::optional<Selection>& selection,
                    const Policy& policy) {
    return to_json(inventory, selection, policy, inspect_runtime());
}

std::string to_json(const Inventory& inventory,
                    const std::optional<Selection>& selection,
                    const Policy& policy,
                    const RuntimeInfo& runtime) {
    const std::optional<Error> result_error = inventory.error
        ? inventory.error
        : selection && selection->error ? selection->error : std::nullopt;
    std::ostringstream output;
    output << "{\"schema\":\"" << kSchema << "\",\"schema_version\":" << kSchemaVersion
           << ",\"backend\":\"amd-hip\",\"status\":\""
           << (result_error ? "error" : "ok") << "\",\"qualified_architectures\":";
    write_string_array(output, physically_tested_architectures());
    output << ",\"compiled_architectures\":";
    write_string_array(output, compiled_architectures());
    output << ",\"rocblas_architectures\":";
    write_string_array(output, runtime.rocblas_architectures);
    output << ",\"physically_tested_architectures\":";
    write_string_array(output, physically_tested_architectures());
    output << ",\"runtime\":{\"available\":"
           << (runtime.available ? "true" : "false")
           << ",\"root\":\"" << json_escape(runtime.root)
           << "\",\"source\":\"" << json_escape(runtime.source)
           << "\",\"version\":\"" << json_escape(runtime.version)
           << "\",\"hip_library\":\"" << json_escape(runtime.hip_library)
           << "\",\"rocblas_library\":\"" << json_escape(runtime.rocblas_library)
           << "\",\"rocblas_library_directory\":\""
           << json_escape(runtime.rocblas_library_directory) << "\",\"error\":";
    write_nullable_string(output, runtime.error);
    output << '}';
    output << ",\"policy\":{\"allow_integrated\":"
           << (policy.allow_integrated ? "true" : "false")
           << ",\"minimum_production_v4_memory_bytes\":"
           << kMinimumProductionV4MemoryBytes
           << ",\"estimated_allocation_bytes\":"
           << (kProductionV4ModelAllocationBytes + kProductionV4WorkspaceAllocationBytes)
           << ",\"memory_safety_margin_bytes\":"
           << kProductionV4MemorySafetyMarginBytes << "},\"devices\":[";
    for (size_t index = 0; index < inventory.devices.size(); ++index) {
        if (index != 0) output << ',';
        const Device& device = inventory.devices[index];
        const auto identifier = stable_id(device);
        const Compatibility compatibility = evaluate_device(device, policy, runtime);
        output << "{\"hip_index\":" << device.hip_index
               << ",\"name\":\"" << json_escape(device.name)
               << "\",\"architecture\":\"" << json_escape(base_architecture(device.architecture))
               << "\",\"architecture_detail\":\"" << json_escape(device.architecture)
               << "\",\"vram_bytes\":" << device.vram_bytes
               << ",\"available_memory_bytes\":";
        write_nullable_uint64(output, device.available_memory_bytes);
        output << ",\"integrated\":";
        write_nullable_bool(output, device.integrated);
        output << ",\"device_type\":\""
               << (!device.integrated ? "unknown" : *device.integrated ? "integrated" : "discrete")
               << "\",\"max_threads_per_block\":" << device.max_threads_per_block
               << ",\"warp_size\":" << device.warp_size
               << ",\"compute_units\":" << device.compute_units
               << ",\"uuid\":";
        write_nullable_string(output, device.uuid);
        output << ",\"pci_bus_id\":";
        write_nullable_string(output, device.pci_bus_id);
        output << ",\"stable_id\":";
        write_nullable_string(output, identifier);
        output << ",\"worker_selector\":\"" << json_escape(worker_selector(device))
               << "\",\"selector_stability\":\""
               << (device.uuid ? "hardware" : device.pci_bus_id ? "topology" : "session")
               << "\",\"architecture_compiled\":"
               << (compatibility.architecture_compiled ? "true" : "false")
               << ",\"rocblas_architecture_available\":"
               << (compatibility.rocblas_architecture_available ? "true" : "false")
               << ",\"total_memory_sufficient\":"
               << (compatibility.total_memory_sufficient ? "true" : "false")
               << ",\"available_memory_sufficient\":"
               << (compatibility.available_memory_sufficient ? "true" : "false")
               << ",\"workgroup_supported\":"
               << (compatibility.workgroup_supported ? "true" : "false")
               << ",\"integrated_allowed\":"
               << (compatibility.integrated_allowed ? "true" : "false")
               << ",\"physically_tested\":"
               << (compatibility.physically_tested ? "true" : "false")
               << ",\"runtime_validation_required\":"
               << (compatibility.runtime_validation_required ? "true" : "false")
               << ",\"compatible\":" << (compatibility.compatible ? "true" : "false")
               << ",\"qualified\":" << (compatibility.compatible ? "true" : "false")
               << ",\"qualification\":\"" << json_escape(compatibility.reason) << "\"}";
    }
    output << "],\"selection\":";
    if (selection && selection->device && !selection->error) {
        const Device& device = *selection->device;
        const Compatibility compatibility = evaluate_device(device, policy, runtime);
        output << "{\"hip_index\":" << device.hip_index
               << ",\"worker_selector\":\"" << json_escape(worker_selector(device))
               << "\",\"name\":\"" << json_escape(device.name)
               << "\",\"architecture\":\"" << json_escape(base_architecture(device.architecture))
               << "\",\"physically_tested\":"
               << (compatibility.physically_tested ? "true" : "false")
               << ",\"runtime_validation_required\":"
               << (compatibility.runtime_validation_required ? "true" : "false") << "}";
    } else {
        output << "null";
    }
    output << ",\"error\":";
    write_error(output, result_error);
    output << '}';
    return output.str();
}

}  // namespace cmfd_hip::discovery
