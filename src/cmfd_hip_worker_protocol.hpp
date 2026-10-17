#pragma once

#include <cstdint>
#include <iosfwd>
#include <string>
#include <string_view>

namespace cmfd_hip::protocol {

enum class ServerExitReason {
    input_closed,
    quit,
};

enum class SigintBehavior {
    terminate,
    defer_to_supervisor,
};

class ServerCommandHandler {
  public:
    virtual ~ServerCommandHandler() = default;
    virtual void run_batch(uint32_t count, const std::string& coefficients,
                           const std::string& output) = 0;
    virtual void evict() = 0;
};

void install_termination_signal_handlers(
    SigintBehavior sigint_behavior = SigintBehavior::terminate);

ServerExitReason run_server_protocol(std::istream& input, std::ostream& output,
                                     std::ostream* diagnostics,
                                     ServerCommandHandler& handler);

std::string_view server_exit_reason_name(ServerExitReason reason);

}  // namespace cmfd_hip::protocol
