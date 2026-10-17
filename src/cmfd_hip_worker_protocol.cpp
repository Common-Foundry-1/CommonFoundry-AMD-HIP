#include "cmfd_hip_worker_protocol.hpp"

#include <charconv>
#include <cerrno>
#include <csignal>
#include <cstring>
#include <istream>
#include <ostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <unistd.h>

namespace cmfd_hip::protocol {
namespace {

enum class CommandKind {
    run_batch,
    evict,
    quit,
};

struct Command {
    CommandKind kind = CommandKind::quit;
    uint32_t count = 0;
    std::string coefficients;
    std::string output;
};

constexpr std::string_view kReadyMarker = "CMFD_V4_REPLAY_READY";
constexpr std::string_view kDoneMarker = "CMFD_V4_REPLAY_DONE";
constexpr std::string_view kEvictedMarker = "CMFD_V4_REPLAY_EVICTED";
volatile std::sig_atomic_t g_defer_sigint_to_supervisor = 0;

void termination_signal_handler(int signal_number) {
    static constexpr char kUnknown[] = "CMFD_HIP_SIGNAL signal=UNKNOWN\n";
    static constexpr char kSigint[] = "CMFD_HIP_SIGNAL signal=SIGINT number=2\n";
    static constexpr char kDeferredSigint[] =
        "CMFD_HIP_SIGNAL signal=SIGINT number=2 action=deferred_to_supervisor\n";
    static constexpr char kSigterm[] = "CMFD_HIP_SIGNAL signal=SIGTERM number=15\n";
    static constexpr char kSighup[] = "CMFD_HIP_SIGNAL signal=SIGHUP number=1\n";
    if (signal_number == SIGINT && g_defer_sigint_to_supervisor != 0) {
        const ssize_t written =
            ::write(STDERR_FILENO, kDeferredSigint, sizeof(kDeferredSigint) - 1);
        if (written < 0) {
            // There is no async-signal-safe diagnostic fallback.
        }
        return;
    }
    const char* message = kUnknown;
    size_t length = sizeof(kUnknown) - 1;
    int exit_code = 128 + signal_number;
    switch (signal_number) {
        case SIGINT:
            message = kSigint;
            length = sizeof(kSigint) - 1;
            break;
        case SIGTERM:
            message = kSigterm;
            length = sizeof(kSigterm) - 1;
            break;
        case SIGHUP:
            message = kSighup;
            length = sizeof(kSighup) - 1;
            break;
        default:
            break;
    }
    const ssize_t written = ::write(STDERR_FILENO, message, length);
    if (written < 0) {
        // There is no safe recovery path in a termination signal handler.
    }
    ::_exit(exit_code);
}

void install_signal_handler(int signal_number) {
    struct sigaction action {};
    action.sa_handler = termination_signal_handler;
    action.sa_flags = SA_RESTART;
    if (::sigemptyset(&action.sa_mask) != 0
        || ::sigaction(signal_number, &action, nullptr) != 0) {
        throw std::runtime_error(
            "cannot install termination signal handler: " + std::string(std::strerror(errno)));
    }
}

void ignore_signal(int signal_number) {
    struct sigaction action {};
    action.sa_handler = SIG_IGN;
    if (::sigemptyset(&action.sa_mask) != 0
        || ::sigaction(signal_number, &action, nullptr) != 0) {
        throw std::runtime_error(
            "cannot ignore pipe signal: " + std::string(std::strerror(errno)));
    }
}

std::vector<std::string> split_fields(const std::string& line) {
    std::vector<std::string> fields;
    size_t start = 0;
    while (true) {
        const size_t separator = line.find('\t', start);
        fields.emplace_back(line.substr(start, separator - start));
        if (separator == std::string::npos) break;
        start = separator + 1;
    }
    return fields;
}

uint32_t parse_batch_count(std::string_view value) {
    uint32_t count = 0;
    const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), count);
    if (error != std::errc{} || end != value.data() + value.size() || count < 1 || count > 64)
        throw std::runtime_error("invalid persistent replay batch size");
    return count;
}

Command parse_command(std::string line) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const std::vector<std::string> fields = split_fields(line);
    if (fields.size() == 1 && fields[0] == "QUIT") return {CommandKind::quit, 0, {}, {}};
    if (fields.size() == 1 && fields[0] == "EVICT") return {CommandKind::evict, 0, {}, {}};
    if (fields.size() == 4 && fields[0] == "RUNBATCH"
        && !fields[1].empty() && !fields[2].empty() && !fields[3].empty()) {
        return {CommandKind::run_batch, parse_batch_count(fields[1]), fields[2], fields[3]};
    }
    throw std::runtime_error("invalid persistent replay command");
}

void emit_marker(std::ostream& output, std::string_view marker) {
    output << marker << '\n';
    output.flush();
    if (!output) throw std::runtime_error("cannot flush persistent replay marker");
}

void emit_diagnostic(std::ostream* diagnostics, uint64_t sequence,
                     std::string_view command, std::string_view phase) {
    if (!diagnostics) return;
    *diagnostics << "CMFD_HIP_PROTOCOL sequence=" << sequence
                 << " command=" << command << " phase=" << phase << '\n';
    diagnostics->flush();
}

void emit_exit(std::ostream* diagnostics, ServerExitReason reason, uint64_t commands) {
    if (!diagnostics) return;
    *diagnostics << "CMFD_HIP_SERVER_EXIT reason=" << server_exit_reason_name(reason)
                 << " commands=" << commands << '\n';
    diagnostics->flush();
}

}  // namespace

void install_termination_signal_handlers(SigintBehavior sigint_behavior) {
    g_defer_sigint_to_supervisor =
        sigint_behavior == SigintBehavior::defer_to_supervisor ? 1 : 0;
    install_signal_handler(SIGINT);
    install_signal_handler(SIGTERM);
    install_signal_handler(SIGHUP);
    ignore_signal(SIGPIPE);
}

ServerExitReason run_server_protocol(std::istream& input, std::ostream& output,
                                     std::ostream* diagnostics,
                                     ServerCommandHandler& handler) {
    emit_marker(output, kReadyMarker);
    uint64_t sequence = 0;
    std::string line;
    while (std::getline(input, line)) {
        ++sequence;
        std::string_view command_name = "PARSE";
        try {
            const Command command = parse_command(std::move(line));
            switch (command.kind) {
                case CommandKind::run_batch:
                    command_name = "RUNBATCH";
                    handler.run_batch(command.count, command.coefficients, command.output);
                    emit_marker(output, kDoneMarker);
                    emit_diagnostic(diagnostics, sequence, command_name, "done");
                    break;
                case CommandKind::evict:
                    command_name = "EVICT";
                    handler.evict();
                    emit_marker(output, kEvictedMarker);
                    emit_diagnostic(diagnostics, sequence, command_name, "done");
                    break;
                case CommandKind::quit:
                    command_name = "QUIT";
                    emit_exit(diagnostics, ServerExitReason::quit, sequence);
                    return ServerExitReason::quit;
            }
        } catch (...) {
            emit_diagnostic(diagnostics, sequence, command_name, "error");
            throw;
        }
    }
    if (!input.eof()) throw std::runtime_error("cannot read persistent replay command pipe");
    emit_exit(diagnostics, ServerExitReason::input_closed, sequence);
    return ServerExitReason::input_closed;
}

std::string_view server_exit_reason_name(ServerExitReason reason) {
    switch (reason) {
        case ServerExitReason::input_closed:
            return "stdin_eof";
        case ServerExitReason::quit:
            return "quit";
    }
    return "unknown";
}

}  // namespace cmfd_hip::protocol
