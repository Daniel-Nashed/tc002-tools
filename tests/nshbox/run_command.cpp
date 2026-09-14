#include "run_command.hpp"

#include <array>
#include <cerrno>
#include <cstring>
#include <stdexcept>

#include <sys/wait.h>
#include <unistd.h>

namespace nshtest {

namespace {

void close_fd(int fd)
{
    if (fd >= 0)
        ::close(fd);
}

void drain(int fd, std::string &out)
{
    std::array<char, 4096> buf{};
    ssize_t n;

    while ((n = ::read(fd, buf.data(), buf.size())) > 0)
        out.append(buf.data(), static_cast<size_t>(n));
}

} // namespace

CommandResult run_command(const std::string &path, const std::vector<std::string> &args,
                           const std::string &stdin_data)
{
    int in_pipe[2];
    int out_pipe[2];
    int err_pipe[2];

    if (::pipe(in_pipe) != 0 || ::pipe(out_pipe) != 0 || ::pipe(err_pipe) != 0)
        throw std::runtime_error(std::string("pipe: ") + std::strerror(errno));

    pid_t pid = ::fork();

    if (pid < 0)
        throw std::runtime_error(std::string("fork: ") + std::strerror(errno));

    if (pid == 0) {
        // Child: wire the pipes to stdin/stdout/stderr, then exec.
        ::dup2(in_pipe[0], STDIN_FILENO);
        ::dup2(out_pipe[1], STDOUT_FILENO);
        ::dup2(err_pipe[1], STDERR_FILENO);

        close_fd(in_pipe[0]);
        close_fd(in_pipe[1]);
        close_fd(out_pipe[0]);
        close_fd(out_pipe[1]);
        close_fd(err_pipe[0]);
        close_fd(err_pipe[1]);

        std::vector<char *> argv;
        argv.push_back(const_cast<char *>(path.c_str()));

        for (const auto &arg : args)
            argv.push_back(const_cast<char *>(arg.c_str()));

        argv.push_back(nullptr);

        ::execvp(path.c_str(), argv.data());

        // execvp() only returns on failure - 127 matches a shell's own
        // "command not found" convention, so a missing reference tool
        // shows up as a recognizable exit code rather than a silent 1.
        _exit(127);
    }

    // Parent.
    close_fd(in_pipe[0]);
    close_fd(out_pipe[1]);
    close_fd(err_pipe[1]);

    // Written before draining stdout/stderr - a real deadlock risk in
    // general (a child that fills a pipe buffer writing output before
    // reading a large stdin could wedge both sides), but every fixture
    // this harness feeds through stdin is small (test file contents, not
    // bulk data), well under a pipe's default buffer size, so this stays
    // simple rather than reaching for select()/poll()-based full-duplex
    // I/O a test-only harness does not need.
    size_t written = 0;

    while (written < stdin_data.size()) {
        ssize_t n = ::write(in_pipe[1], stdin_data.data() + written, stdin_data.size() - written);

        if (n < 0) {
            if (errno == EINTR)
                continue;
            break;
        }

        written += static_cast<size_t>(n);
    }

    close_fd(in_pipe[1]);

    CommandResult result;

    drain(out_pipe[0], result.stdout_data);
    drain(err_pipe[0], result.stderr_data);

    close_fd(out_pipe[0]);
    close_fd(err_pipe[0]);

    int status = 0;
    ::waitpid(pid, &status, 0);

    if (WIFEXITED(status))
        result.exit_code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status))
        result.exit_code = 128 + WTERMSIG(status);

    return result;
}

} // namespace nshtest
