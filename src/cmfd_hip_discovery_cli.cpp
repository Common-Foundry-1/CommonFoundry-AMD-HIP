#include "cmfd_hip_discovery.hpp"

#include <iostream>
#include <optional>
#include <string>

int main(int argc, char** argv) {
    std::optional<std::string> selector;
    bool auto_select = false;
    std::optional<cmfd_hip::discovery::Error> cli_error;
    cmfd_hip::discovery::Policy policy;

    try {
        policy = cmfd_hip::discovery::policy_from_environment();
    } catch (const std::exception& error) {
        cli_error = cmfd_hip::discovery::Error{
            "invalid_configuration", error.what(), 2};
    }

    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--list") {
            continue;
        }
        if (argument == "--auto-select") {
            auto_select = true;
            continue;
        }
        if (argument == "--select") {
            if (++index >= argc) {
                cli_error = cmfd_hip::discovery::Error{
                    "invalid_arguments", "--select requires one device selector", 2};
                break;
            }
            selector = argv[index];
            continue;
        }
        cli_error = cmfd_hip::discovery::Error{
            "invalid_arguments",
            "Usage: cmfd-hip-discovery [--list] [--auto-select | --select SELECTOR]", 2};
        break;
    }
    if (auto_select && selector) {
        cli_error = cmfd_hip::discovery::Error{
            "invalid_arguments", "--auto-select and --select are mutually exclusive", 2};
    }

    cmfd_hip::discovery::Inventory inventory;
    const auto runtime = cmfd_hip::discovery::inspect_runtime();
    if (cli_error) {
        inventory.error = cli_error;
        std::cout << cmfd_hip::discovery::to_json(
            inventory, std::nullopt, policy, runtime) << '\n';
        return cli_error->exit_code;
    }

    inventory = cmfd_hip::discovery::discover_devices(runtime);
    if (inventory.error) {
        std::cout << cmfd_hip::discovery::to_json(
            inventory, std::nullopt, policy, runtime) << '\n';
        return inventory.error->exit_code;
    }
    if (auto_select || selector) {
        const auto selection =
            cmfd_hip::discovery::select_device(inventory.devices, selector, policy, runtime);
        std::cout << cmfd_hip::discovery::to_json(
            inventory, selection, policy, runtime) << '\n';
        return selection.error ? selection.error->exit_code : 0;
    }
    std::cout << cmfd_hip::discovery::to_json(
        inventory, std::nullopt, policy, runtime) << '\n';
    return 0;
}
