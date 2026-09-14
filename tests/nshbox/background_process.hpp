// RAII handle for a process that keeps running after being spawned -
// pstree needs a real, currently-alive process tree to inspect, unlike
// every other command here (run_command() runs a command to completion
// and captures its output, which is no use when the whole point is
// observing something while it is still running).
#pragma once

#include <string>
#include <vector>

#include <sys/types.h>

namespace nshtest {

// Spawns path with args in the background (does not wait for it to
// exit). Sends SIGTERM (escalating to SIGKILL if it has not exited
// shortly after) and reaps it via waitpid() when this object goes out of
// scope, the same cleanup guarantee TempDir gives for fixture
// directories, just for a process instead of a filesystem path - so a
// failing test never leaves an orphaned process behind either.
class BackgroundProcess
{
public:
    BackgroundProcess(const std::string &path, const std::vector<std::string> &args);
    ~BackgroundProcess();

    BackgroundProcess(const BackgroundProcess &) = delete;
    BackgroundProcess &operator=(const BackgroundProcess &) = delete;
    BackgroundProcess(BackgroundProcess &&other) noexcept;
    BackgroundProcess &operator=(BackgroundProcess &&other) noexcept;

    pid_t pid() const { return pid_; }

private:
    void terminate_and_reap();

    pid_t pid_ = -1;
};

} // namespace nshtest
