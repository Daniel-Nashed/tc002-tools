#include "background_process.hpp"

#include <cerrno>
#include <cstring>
#include <stdexcept>
#include <utility>

#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

namespace nshtest {

BackgroundProcess::BackgroundProcess(const std::string &path, const std::vector<std::string> &args)
{
    pid_t pid = ::fork();

    if (pid < 0)
        throw std::runtime_error(std::string("fork: ") + std::strerror(errno));

    if (pid == 0) {
        // Its own process group, not the harness's - terminate_and_reap()
        // below kills the whole group (-pid_) so a shell fixture's own
        // backgrounded children (which inherit their parent's process
        // group by default, since a non-interactive "sh -c '... & ...'"
        // has job control off) get signaled too, not just the shell
        // itself. Without this, kill(-pid_, ...) would target whatever
        // group this child happened to inherit (the test harness's own),
        // not a group this child actually leads.
        ::setpgid(0, 0);

        // Child: no output expected or wanted from these fixtures, so
        // stdin/stdout/stderr all go to /dev/null rather than cluttering
        // (or blocking on) the test harness's own streams.
        int devnull = ::open("/dev/null", O_RDWR);

        if (devnull >= 0) {
            ::dup2(devnull, STDIN_FILENO);
            ::dup2(devnull, STDOUT_FILENO);
            ::dup2(devnull, STDERR_FILENO);

            if (devnull > STDERR_FILENO)
                ::close(devnull);
        }

        std::vector<char *> argv;
        argv.push_back(const_cast<char *>(path.c_str()));

        for (const auto &arg : args)
            argv.push_back(const_cast<char *>(arg.c_str()));

        argv.push_back(nullptr);

        ::execvp(path.c_str(), argv.data());
        _exit(127);
    }

    pid_ = pid;
}

BackgroundProcess::~BackgroundProcess()
{
    terminate_and_reap();
}

BackgroundProcess::BackgroundProcess(BackgroundProcess &&other) noexcept : pid_(other.pid_)
{
    other.pid_ = -1;
}

BackgroundProcess &BackgroundProcess::operator=(BackgroundProcess &&other) noexcept
{
    if (this != &other) {
        terminate_and_reap();
        pid_ = other.pid_;
        other.pid_ = -1;
    }

    return *this;
}

void BackgroundProcess::terminate_and_reap()
{
    if (pid_ <= 0)
        return;

    // SIGTERM first, then a short poll for a clean exit before
    // escalating to SIGKILL - most of these fixtures are just "sh -c
    // '... & ... & wait'" trees, so SIGTERM alone is usually enough, but
    // the shell's own backgrounded children are not guaranteed to also
    // receive it (SIGTERM to the shell does not automatically propagate
    // to jobs it started), hence killing the whole process GROUP (a
    // negative pid to kill()) rather than just the one pid this object
    // tracks.
    ::kill(-pid_, SIGTERM);

    for (int attempt = 0; attempt < 20; attempt++) {
        int status;
        pid_t result = ::waitpid(pid_, &status, WNOHANG);

        if (result == pid_ || result < 0)
            return;

        struct timespec delay = {0, 10 * 1000 * 1000}; // 10ms
        ::nanosleep(&delay, nullptr);
    }

    ::kill(-pid_, SIGKILL);
    ::waitpid(pid_, nullptr, 0);
}

} // namespace nshtest
