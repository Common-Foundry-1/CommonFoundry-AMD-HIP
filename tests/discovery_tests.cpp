#include "cmfd_hip_discovery.hpp"

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

using cmfd_hip::discovery::Device;
using cmfd_hip::discovery::Error;
using cmfd_hip::discovery::Inventory;
using cmfd_hip::discovery::Policy;
using cmfd_hip::discovery::RuntimeInfo;
using cmfd_hip::discovery::Selection;

namespace {

constexpr uint64_t kGiB = 1024ULL * 1024 * 1024;

[[noreturn]] void fail(const std::string& message) {
    std::cerr << "DISCOVERY TEST FAIL: " << message << '\n';
    std::exit(1);
}

void require(bool condition, const std::string& message) {
    if (!condition) fail(message);
}

Device device(int index, std::string architecture,
              std::optional<std::string> uuid = std::nullopt,
              std::optional<std::string> pci = std::nullopt,
              uint64_t memory = 24 * kGiB,
              std::optional<bool> integrated = false,
              int max_threads = 1024) {
    Device result;
    result.hip_index = index;
    result.name = "Fixture GPU " + std::to_string(index);
    result.architecture = std::move(architecture);
    result.vram_bytes = memory;
    result.uuid = std::move(uuid);
    result.pci_bus_id = std::move(pci);
    result.available_memory_bytes = memory;
    result.integrated = integrated;
    result.max_threads_per_block = max_threads;
    result.warp_size = 32;
    result.compute_units = 80;
    return result;
}

RuntimeInfo fixture_runtime(std::vector<std::string> architectures = {"gfx1100"}) {
    RuntimeInfo runtime;
    runtime.available = true;
    runtime.root = "/fixture/rocm";
    runtime.source = "fixture";
    runtime.version = "7.14.0-test";
    runtime.hip_library = "/fixture/rocm/lib/libamdhip64.so.7";
    runtime.rocblas_library = "/fixture/rocm/lib/librocblas.so.5";
    runtime.rocblas_library_directory = "/fixture/rocm/lib/rocblas/library";
    runtime.rocblas_architectures = std::move(architectures);
    return runtime;
}

Selection select(const std::vector<Device>& devices,
                 const std::optional<std::string>& selector,
                 const Policy& policy = {}) {
    return cmfd_hip::discovery::select_device(
        devices, selector, policy, fixture_runtime());
}

std::string json(const Inventory& inventory,
                 const std::optional<Selection>& selection = std::nullopt,
                 const Policy& policy = {}) {
    return cmfd_hip::discovery::to_json(
        inventory, selection, policy, fixture_runtime());
}

std::vector<Inventory> fixture_inventories() {
    return {
        {{device(0, "gfx1100", "00112233-4455-6677-8899-aabbccddeeff",
                  "0000:03:00.0")}, std::nullopt},
        {{device(0, "gfx1100", "00112233-4455-6677-8899-aabbccddeeff"),
          device(1, "gfx1036", std::nullopt, "0000:0d:00.0", 15 * kGiB, true)},
         std::nullopt},
        {{device(2, "gfx1100")}, std::nullopt},
        {{}, std::nullopt},
        {{}, Error{"hip_runtime_unavailable", "AMD HIP runtime is unavailable", 3}},
        {{device(0, "gfx1036")}, std::nullopt},
        {{device(0, "gfx1100", std::nullopt, std::nullopt, 4 * kGiB)}, std::nullopt},
        {{device(0, "gfx9999")}, std::nullopt},
        {{}, Error{"hip_discovery_failed", "fixture discovery failure", 4}},
        {{}, Error{"rocblas_initialization_failed", "fixture rocBLAS failure", 11}},
    };
}

}  // namespace

int main(int argc, char** argv) {
    const Device qualified = device(0, "gfx1100:xnack-",
                                    "00112233-4455-6677-8899-aabbccddeeff",
                                    "0000:03:00.0");
    require(cmfd_hip::discovery::is_qualified(qualified, {}, fixture_runtime()),
            "gfx1100 feature suffix must remain qualified");
    require(cmfd_hip::discovery::worker_selector(qualified)
                == "uuid:00112233-4455-6677-8899-aabbccddeeff",
            "UUID must be the preferred stable selector");

    const auto compiled = cmfd_hip::discovery::compiled_architectures();
    require(std::find(compiled.begin(), compiled.end(), "gfx1036") != compiled.end()
                && std::find(compiled.begin(), compiled.end(), "gfx1100") != compiled.end(),
            "multi-architecture build must embed gfx1036 and gfx1100");

    {
        const std::vector<Device> devices = {qualified};
        const Selection selected = select(devices, std::nullopt);
        require(selected.device == &devices.front() && !selected.error,
                "one compatible dedicated GPU must auto-select");
    }
    {
        const std::vector<Device> devices = {
            qualified,
            device(1, "gfx1100", "11112233-4455-6677-8899-aabbccddeeff",
                   "0000:04:00.0")};
        const Selection automatic = select(devices, std::nullopt);
        require(automatic.error && automatic.error->code == "ambiguous_selector",
                "multiple compatible GPUs must require explicit selection");
        const Selection selected = select(
            devices, std::string("pci:0000:04:00.0"));
        require(selected.device == &devices[1] && !selected.error,
                "PCI selector must identify the intended HIP device");
        const Selection first = select(
            devices, cmfd_hip::discovery::stable_id(devices[0]));
        require(first.device == &devices[0] && !first.error,
                "UUID selector must identify the intended HIP device");
        const Selection by_index = select(
            devices, std::string("hip:1"));
        require(by_index.device == &devices[1] && !by_index.error,
                "HIP index selector must identify the intended compatible device");
        const Inventory inventory{devices, std::nullopt};
        const std::string document = json(inventory, automatic);
        require(document.find("uuid:00112233-4455-6677-8899-aabbccddeeff") != std::string::npos
                    && document.find("uuid:11112233-4455-6677-8899-aabbccddeeff") != std::string::npos
                    && document.find("0000:04:00.0") != std::string::npos,
                "ambiguous auto-selection must enumerate every selector");
    }
    {
        const std::vector<Device> devices = {device(2, "gfx1100")};
        require(!cmfd_hip::discovery::stable_id(devices.front()),
                "missing hardware IDs must remain explicit");
        require(cmfd_hip::discovery::worker_selector(devices.front()) == "hip:2",
                "session-scoped HIP selector must be the fallback");
        const Selection selected = select(
            devices, std::string("hip:2"));
        require(selected.device == &devices.front() && !selected.error,
                "explicit HIP index must select an ID-less device");
    }
    {
        const Device integrated = device(
            0, "gfx1100", std::nullopt, "0000:0d:00.0", 16 * kGiB, true);
        const std::vector<Device> devices = {integrated};
        const Selection blocked =
            select(devices, std::string("hip:0"));
        require(blocked.error && blocked.error->code == "integrated_device_disabled",
                "integrated GPU must be excluded by the safe default");
        const Selection opted_in =
            select(devices, std::string("hip:0"), Policy{true});
        require(opted_in.device == &devices.front() && !opted_in.error,
                "compatible integrated GPU must be selectable after explicit opt-in");
    }
    {
        const std::vector<Device> devices = {
            qualified,
            device(1, "gfx1100", std::nullopt, "0000:0d:00.0", 16 * kGiB, true)};
        const Selection automatic = select(devices, std::nullopt, Policy{true});
        require(automatic.device == &devices.front() && !automatic.error,
                "one compatible dedicated GPU must be preferred over opted-in integrated GPUs");
        const Selection explicit_integrated =
            select(devices, std::string("pci:0000:0d:00.0"), Policy{true});
        require(explicit_integrated.device == &devices[1] && !explicit_integrated.error,
                "integrated GPU must remain explicitly selectable when a dedicated GPU exists");
    }
    {
        const std::vector<Device> devices = {
            qualified,
            device(1, "gfx1036", std::nullopt, "0000:0d:00.0", 16 * kGiB, true)};
        const Selection selected =
            select(devices, std::nullopt);
        require(selected.device == &devices.front() && !selected.error,
                "one compatible device plus one incompatible device must auto-select");
        const Selection unavailable = select(
            devices, std::string("hip:1"), Policy{true});
        require(unavailable.error
                    && unavailable.error->code == "rocblas_architecture_unavailable",
                "compiled architecture without packaged rocBLAS support must be rejected");
    }
    {
        const std::vector<Device> devices = {
            device(0, "gfx1100", std::nullopt, std::nullopt, 4 * kGiB)};
        const Selection selected = select(
            devices, std::string("hip:0"));
        require(selected.error && selected.error->code == "insufficient_memory",
                "insufficient ProductionV4 memory must be rejected");
    }
    {
        const std::vector<Device> devices = {
            device(0, "gfx1100", std::nullopt, std::nullopt, 8 * kGiB)};
        const Selection selected = select(devices, std::string("hip:0"));
        require(selected.device == &devices.front() && !selected.error,
                "an otherwise capable 8 GiB GPU must not be rejected by an arbitrary 8 GiB free-memory floor");
        Device constrained = devices.front();
        constrained.available_memory_bytes =
            cmfd_hip::discovery::kMinimumProductionV4MemoryBytes - 1;
        const std::vector<Device> constrained_devices = {constrained};
        const Selection rejected = select(constrained_devices, std::string("hip:0"));
        require(rejected.error && rejected.error->code == "insufficient_memory",
                "measured allocation floor plus safety margin must still be enforced");
    }
    {
        const std::vector<Device> devices = {device(0, "gfx9999")};
        const Selection selected = select(
            devices, std::string("hip:0"));
        require(selected.error && selected.error->code == "architecture_not_compiled",
                "architecture missing from the fat binary must be rejected");
    }
    {
        const std::vector<Device> devices = {
            device(0, "gfx1100", std::nullopt, std::nullopt, 24 * kGiB, false, 256)};
        const Selection selected = select(
            devices, std::string("hip:0"));
        require(selected.error && selected.error->code == "capability_not_supported",
                "device unable to launch required workgroups must be rejected");
    }
    {
        const Selection selected = select({}, std::nullopt);
        require(selected.error && selected.error->code == "no_qualified_device",
                "empty discovery must report no compatible device");
    }
    {
        const std::vector<Device> devices = {qualified};
        const Selection invalid = select(
            devices, std::string("GPU 0"));
        require(invalid.error && invalid.error->code == "invalid_selector",
                "free-form selectors must be rejected");
        const Selection malformed = select(
            devices, std::string("uuid:not-a-uuid"));
        require(malformed.error && malformed.error->code == "invalid_selector",
                "malformed stable selectors must be rejected");
        const Selection missing = select(
            devices, std::string("hip:99"));
        require(missing.error && missing.error->code == "device_not_found",
                "unknown explicit selector must be rejected");
    }
    {
        const std::vector<Device> devices = {
            qualified,
            device(1, "gfx1100", qualified.uuid, "0000:04:00.0")};
        const Selection duplicate = select(
            devices, cmfd_hip::discovery::stable_id(qualified));
        require(duplicate.error && duplicate.error->code == "ambiguous_selector",
                "duplicate stable IDs must be rejected as ambiguous");
    }

    const std::vector<Inventory> inventories = fixture_inventories();
    for (const Inventory& inventory : inventories) {
        const std::string document = json(inventory);
        require(document.starts_with('{') && document.ends_with('}'),
                "fixture output must have a JSON object envelope");
        require(document.find("\"schema_version\":1") != std::string::npos,
                "fixture output must carry schema version 1");
    }

    if (argc == 2 && std::string(argv[1]) == "--json-fixtures") {
        for (const Inventory& inventory : inventories)
            std::cout << json(inventory) << '\n';
        Inventory inventory{{qualified}, std::nullopt};
        const Selection selected = select(
            inventory.devices, std::nullopt);
        std::cout << json(inventory, selected) << '\n';
        for (const std::optional<std::string>& selector : {
                 std::optional<std::string>("invalid"),
                 std::optional<std::string>("hip:99")}) {
            const Selection rejected = select(
                inventory.devices, selector);
            std::cout << json(inventory, rejected) << '\n';
        }
        Inventory integrated{{
            device(0, "gfx1100", std::nullopt, "0000:0d:00.0", 16 * kGiB, true)},
            std::nullopt};
        const Selection blocked = select(
            integrated.devices, std::string("hip:0"));
        std::cout << json(integrated, blocked) << '\n';
        const Selection allowed = select(
            integrated.devices, std::string("hip:0"), Policy{true});
        std::cout << json(integrated, allowed, Policy{true}) << '\n';
        Inventory ambiguous{{
            qualified,
            device(1, "gfx1100", qualified.uuid, "0000:04:00.0")}, std::nullopt};
        const Selection duplicate = select(
            ambiguous.devices, cmfd_hip::discovery::stable_id(qualified));
        std::cout << json(ambiguous, duplicate) << '\n';
        return 0;
    }

    std::cout << "CMFD_HIP_DISCOVERY_TEST PASS cases=17\n";
    return 0;
}
