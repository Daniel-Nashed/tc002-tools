// Runs a command and captures its output - the harness's only way of
// invoking both nshbox itself and the real platform reference tools it
// is diffed against.
#pragma once

#include <string>
#include <vector>

namespace nshtest {

struct CommandResult
{
    std::string stdout_data;
    std::string stderr_data;
    int exit_code = -1;
};

// Runs path with the given args (argv[0] is path itself, matching normal
// invocation), capturing stdout/stderr separately and optionally feeding
// stdin_data to the child's stdin before closing it. Resolved via
// execvp() - a bare name like "grep" searches PATH (this is a controlled
// container with a normal, guaranteed PATH, unlike the TC002 device
// nshbox itself has to work around - see nshbox/README.md), a path
// containing '/' is used directly either way. fork()+execvp()+pipe(),
// not popen()/system() - the argv vector reaches the child directly,
// never interpreted by a shell, matching this project's own reasoning
// for nshbox's own tar-via-gzip design (see nshbox/src/nshbox.c).
CommandResult run_command(const std::string &path, const std::vector<std::string> &args,
                           const std::string &stdin_data = "");

} // namespace nshtest
