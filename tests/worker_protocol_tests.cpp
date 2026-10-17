#include "cmfd_hip_worker_protocol.hpp"

#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

#include <sys/wait.h>
#include <unistd.h>

namespace {

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

class FakeHandler final : public cmfd_hip::protocol::ServerCommandHandler {
  public:
    void run_batch(uint32_t count, const std::string& coefficients,
                   const std::string& output) override {
        if (fail_run) throw std::runtime_error("fixture run failure");
        if (signal_on_run != 0) ::raise(signal_on_run);
        run_count = count;
        coefficient_path = coefficients;
        output_path = output;
        ++runs;
    }

    void evict() override { ++evictions; }

    bool fail_run = false;
    int signal_on_run = 0;
    uint32_t run_count = 0;
    unsigned int runs = 0;
    unsigned int evictions = 0;
    std::string coefficient_path;
    std::string output_path;
};

struct ChildResult {
    int status = 0;
    std::string output;
    std::string diagnostics;
};

std::string read_all(int descriptor) {
    std::string contents;
    char buffer[256];
    while (true) {
        const ssize_t count = ::read(descriptor, buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0) {
            if (errno == EINTR) continue;
            throw std::runtime_error("cannot read child test pipe");
        }
        contents.append(buffer, static_cast<size_t>(count));
    }
    return contents;
}

ChildResult run_signal_during_batch_child(
    int signal_number, cmfd_hip::protocol::SigintBehavior sigint_behavior) {
    int output_descriptors[2]{};
    int diagnostic_descriptors[2]{};
    require(::pipe(output_descriptors) == 0, "cannot create signal output pipe");
    require(::pipe(diagnostic_descriptors) == 0, "cannot create signal diagnostic pipe");
    const pid_t child = ::fork();
    require(child >= 0, "cannot fork signal-during-batch test child");
    if (child == 0) {
        ::close(output_descriptors[0]);
        ::close(diagnostic_descriptors[0]);
        if (::dup2(output_descriptors[1], STDOUT_FILENO) < 0
            || ::dup2(diagnostic_descriptors[1], STDERR_FILENO) < 0)
            ::_exit(90);
        ::close(output_descriptors[1]);
        ::close(diagnostic_descriptors[1]);
        try {
            cmfd_hip::protocol::install_termination_signal_handlers(sigint_behavior);
            std::istringstream input("RUNBATCH\t32\ta\tb\nQUIT\n");
            FakeHandler handler;
            handler.signal_on_run = signal_number;
            const auto reason = cmfd_hip::protocol::run_server_protocol(
                input, std::cout, &std::cerr, handler);
            std::cout.flush();
            std::cerr.flush();
            ::_exit(reason == cmfd_hip::protocol::ServerExitReason::quit ? 0 : 91);
        } catch (...) {
            ::_exit(92);
        }
    }
    ::close(output_descriptors[1]);
    ::close(diagnostic_descriptors[1]);
    ChildResult result;
    result.output = read_all(output_descriptors[0]);
    result.diagnostics = read_all(diagnostic_descriptors[0]);
    ::close(output_descriptors[0]);
    ::close(diagnostic_descriptors[0]);
    require(::waitpid(child, &result.status, 0) == child,
            "cannot wait for signal-during-batch test child");
    return result;
}

template <typename Function>
void require_throws(Function function, const char* message) {
    try {
        function();
    } catch (const std::exception&) {
        return;
    }
    throw std::runtime_error(message);
}

void test_normal_protocol() {
    std::istringstream input(
        "RUNBATCH\t32\t/tmp/path with spaces/input.bin\t/tmp/output path/batch\r\n"
        "EVICT\nQUIT\n");
    std::ostringstream output;
    std::ostringstream diagnostics;
    FakeHandler handler;
    const auto reason = cmfd_hip::protocol::run_server_protocol(
        input, output, &diagnostics, handler);
    require(reason == cmfd_hip::protocol::ServerExitReason::quit,
            "QUIT must report a normal quit");
    require(handler.runs == 1 && handler.run_count == 32,
            "RUNBATCH must reach the handler once");
    require(handler.coefficient_path == "/tmp/path with spaces/input.bin",
            "tab protocol must preserve spaces in coefficient paths");
    require(handler.output_path == "/tmp/output path/batch",
            "tab protocol must preserve spaces in output paths");
    require(handler.evictions == 1, "EVICT must reach the handler once");
    require(output.str() == "CMFD_V4_REPLAY_READY\nCMFD_V4_REPLAY_DONE\nCMFD_V4_REPLAY_EVICTED\n",
            "normal protocol markers changed");
    require(diagnostics.str().find("reason=quit") != std::string::npos,
            "normal quit diagnostic is missing");
}

void test_eof_protocol() {
    std::istringstream input;
    std::ostringstream output;
    std::ostringstream diagnostics;
    FakeHandler handler;
    const auto reason = cmfd_hip::protocol::run_server_protocol(
        input, output, &diagnostics, handler);
    require(reason == cmfd_hip::protocol::ServerExitReason::input_closed,
            "EOF must be distinguishable from QUIT");
    require(diagnostics.str().find("reason=stdin_eof") != std::string::npos,
            "EOF diagnostic is missing");
}

void test_error_protocol() {
    for (const std::string& command : {
             std::string("UNKNOWN\n"), std::string("RUNBATCH 32 a b\n"),
             std::string("RUNBATCH\t0\ta\tb\n"), std::string("RUNBATCH\t65\ta\tb\n")}) {
        std::istringstream input(command);
        std::ostringstream output;
        FakeHandler handler;
        require_throws(
            [&] { cmfd_hip::protocol::run_server_protocol(input, output, nullptr, handler); },
            "invalid protocol command must fail");
    }

    std::istringstream input("RUNBATCH\t32\ta\tb\n");
    std::ostringstream output;
    std::ostringstream diagnostics;
    FakeHandler handler;
    handler.fail_run = true;
    require_throws(
        [&] { cmfd_hip::protocol::run_server_protocol(input, output, &diagnostics, handler); },
        "handler failure must escape the server loop");
    require(output.str().find("CMFD_V4_REPLAY_DONE") == std::string::npos,
            "failed work must never emit DONE");
    require(diagnostics.str().find("command=RUNBATCH phase=error") != std::string::npos,
            "handler failure diagnostic must identify RUNBATCH");
}

void test_marker_failure() {
    std::istringstream input;
    std::ostringstream output;
    output.setstate(std::ios::badbit);
    FakeHandler handler;
    require_throws(
        [&] { cmfd_hip::protocol::run_server_protocol(input, output, nullptr, handler); },
        "failed stdout marker must fail the worker protocol");
}

void test_broken_pipe_diagnostic_path() {
    int descriptors[2]{};
    require(::pipe(descriptors) == 0, "cannot create broken-pipe test pipe");
    ::close(descriptors[0]);
    const pid_t child = ::fork();
    require(child >= 0, "cannot fork broken-pipe test child");
    if (child == 0) {
        if (::dup2(descriptors[1], STDOUT_FILENO) < 0) ::_exit(90);
        ::close(descriptors[1]);
        try {
            cmfd_hip::protocol::install_termination_signal_handlers();
            std::istringstream input;
            FakeHandler handler;
            cmfd_hip::protocol::run_server_protocol(input, std::cout, nullptr, handler);
        } catch (const std::exception&) {
            ::_exit(0);
        }
        ::_exit(91);
    }
    ::close(descriptors[1]);
    int status = 0;
    require(::waitpid(child, &status, 0) == child, "cannot wait for broken-pipe test child");
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "closed stdout must become a catchable marker error, not SIGPIPE");
}

void test_signal_diagnostic() {
    int descriptors[2]{};
    require(::pipe(descriptors) == 0, "cannot create signal test pipe");
    const pid_t child = ::fork();
    require(child >= 0, "cannot fork signal test child");
    if (child == 0) {
        ::close(descriptors[0]);
        if (::dup2(descriptors[1], STDERR_FILENO) < 0) ::_exit(90);
        ::close(descriptors[1]);
        try {
            cmfd_hip::protocol::install_termination_signal_handlers();
        } catch (...) {
            ::_exit(91);
        }
        ::raise(SIGTERM);
        ::_exit(92);
    }

    ::close(descriptors[1]);
    std::string message;
    char buffer[128];
    while (true) {
        const ssize_t count = ::read(descriptors[0], buffer, sizeof(buffer));
        if (count <= 0) break;
        message.append(buffer, static_cast<size_t>(count));
    }
    ::close(descriptors[0]);
    int status = 0;
    require(::waitpid(child, &status, 0) == child, "cannot wait for signal test child");
    require(WIFEXITED(status) && WEXITSTATUS(status) == 143,
            "SIGTERM must produce exit code 143");
    require(message == "CMFD_HIP_SIGNAL signal=SIGTERM number=15\n",
            "SIGTERM diagnostic changed");
}

void test_supervised_sigint_during_batch() {
    const ChildResult result = run_signal_during_batch_child(
        SIGINT, cmfd_hip::protocol::SigintBehavior::defer_to_supervisor);
    require(WIFEXITED(result.status) && WEXITSTATUS(result.status) == 0,
            "supervised SIGINT must allow protocol QUIT");
    require(result.output == "CMFD_V4_REPLAY_READY\nCMFD_V4_REPLAY_DONE\n",
            "supervised SIGINT must not suppress or fabricate DONE");
    require(result.diagnostics.find("signal=SIGINT number=2 action=deferred_to_supervisor")
                != std::string::npos,
            "supervised SIGINT diagnostic is missing");
    require(result.diagnostics.find("command=RUNBATCH phase=done") != std::string::npos,
            "completed batch diagnostic is missing after supervised SIGINT");
    require(result.diagnostics.find("reason=quit") != std::string::npos,
            "supervisor QUIT diagnostic is missing after SIGINT");
}

void test_fatal_signal_during_batch() {
    const ChildResult result = run_signal_during_batch_child(
        SIGTERM, cmfd_hip::protocol::SigintBehavior::defer_to_supervisor);
    require(WIFEXITED(result.status) && WEXITSTATUS(result.status) == 143,
            "SIGTERM during a batch must remain a real worker failure");
    require(result.output == "CMFD_V4_REPLAY_READY\n",
            "fatal interruption must never emit DONE");
    require(result.diagnostics == "CMFD_HIP_SIGNAL signal=SIGTERM number=15\n",
            "fatal interruption diagnostic changed");
}

void test_direct_sigint_during_batch() {
    const ChildResult result = run_signal_during_batch_child(
        SIGINT, cmfd_hip::protocol::SigintBehavior::terminate);
    require(WIFEXITED(result.status) && WEXITSTATUS(result.status) == 130,
            "direct-mode SIGINT must retain exit code 130");
    require(result.output == "CMFD_V4_REPLAY_READY\n",
            "direct-mode SIGINT must never emit DONE");
    require(result.diagnostics == "CMFD_HIP_SIGNAL signal=SIGINT number=2\n",
            "direct-mode SIGINT diagnostic changed");
}

}  // namespace

int main() {
    try {
        test_normal_protocol();
        test_eof_protocol();
        test_error_protocol();
        test_marker_failure();
        test_broken_pipe_diagnostic_path();
        test_signal_diagnostic();
        test_supervised_sigint_during_batch();
        test_fatal_signal_during_batch();
        test_direct_sigint_during_batch();
        std::cout << "CMFD_HIP_WORKER_PROTOCOL_TEST PASS\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "CMFD_HIP_WORKER_PROTOCOL_TEST FAIL: " << error.what() << '\n';
        return 1;
    }
}
