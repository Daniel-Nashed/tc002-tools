// Compares nshbox's pstree (default box-drawing mode) against real
// psmisc pstree(1), rooted at a small, known process tree the test
// itself spawns and controls (BackgroundProcess) rather than the
// container's own ambient process list - a second, independent pstree
// invocation against a live system's *whole* tree would not necessarily
// see the same thing a moment later, but a tree rooted at a PID this
// test owns is fully deterministic for as long as that fixture stays
// alive.
//
// Only trees with NO two same-named siblings are used here: real
// pstree's default behavior compacts identical siblings into "N*[name]"
// (psmisc's own --compact-not/-c flag turns that off, which is passed
// here specifically to get a fair comparison), and nshbox's own pstree
// does not implement that compaction at all - a real, confirmed gap
// (thread merging within one process, "N*[{name}]", is implemented; the
// same compaction across distinct sibling PROCESSES that happen to share
// a name is not). Deliberately out of scope for this pass - the fixtures
// below use only distinct process names (sh vs sleep) at any level where
// more than one child is spawned, sidestepping the gap entirely rather
// than papering over it with a real, unfixed feature difference.
#include "framework.hpp"
#include "run_command.hpp"
#include "background_process.hpp"

#include <string>

#include <time.h>
#include <unistd.h>

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::BackgroundProcess;

namespace {

// Real pstree falls back to ASCII line-drawing off a real terminal, same
// as tree(1) - and compacts identical-sibling subtrees by default, which
// nshbox's pstree does not implement (see file comment above) - -U forces
// Unicode, -c disables that compaction so the comparison is fair for the
// no-same-name-siblings fixtures used here.
std::string run_real_pstree(pid_t pid)
{
    return run_command("pstree", {"-Uc", std::to_string(pid)}).stdout_data;
}

std::string run_nshbox_pstree(pid_t pid)
{
    return run_command(nshbox_path(), {"pstree", std::to_string(pid)}).stdout_data;
}

// Gives a freshly-spawned shell fixture time to actually start its own
// background children before either pstree is asked to look at it.
void settle()
{
    struct timespec delay = {0, 300 * 1000 * 1000}; // 300ms
    nanosleep(&delay, nullptr);
}

} // namespace

TEST_CASE(PstreeSingleChild, "pstree: a single child (no branch at all)")
{
    BackgroundProcess proc("sh", {"-c", "sleep 60"});
    settle();

    ASSERT_EQ(run_nshbox_pstree(proc.pid()), run_real_pstree(proc.pid()),
              "pstree on a single-child process");
}

TEST_CASE(PstreeChainThenBranch, "pstree: a chain of single-child hops ending in a branch")
{
    // sh -> sh -> {sleep, yes} - exercises the exact case that exposed
    // the connector-width/indentation bugs: a single-child connector
    // followed by a branching one, where the branch's own continuation
    // line has to align correctly after TWO levels of accumulated
    // prefix, not just one. "yes" (not "cat"): BackgroundProcess
    // redirects every child's stdin from /dev/null, and "cat" reading
    // /dev/null hits EOF and exits immediately - "yes" writing to
    // /dev/null (also redirected) just keeps looping forever instead,
    // which is what a fixture that has to stay alive actually needs.
    BackgroundProcess proc("sh", {"-c", "sh -c 'sleep 60 & yes & wait'"});
    settle();

    ASSERT_EQ(run_nshbox_pstree(proc.pid()), run_real_pstree(proc.pid()),
              "pstree on a single-child chain ending in a two-way branch");
}

TEST_CASE(PstreeBranchWithChildHavingChildren, "pstree: a branch whose first child has its own children")
{
    // sh -+- sh -+- sleep
    //     |      `- yes
    //     `- sleep
    // Exercises the "|" continuation prefix used for a branch's own
    // first child, when that child needs more than one line of its own.
    BackgroundProcess proc("sh", {"-c", "sh -c 'sleep 60 & yes & wait' & sleep 60 & wait"});
    settle();

    ASSERT_EQ(run_nshbox_pstree(proc.pid()), run_real_pstree(proc.pid()),
              "pstree on a branch whose first child itself branches");
}

TEST_CASE(PstreeThreeWayBranch, "pstree: three distinctly-named children")
{
    // "cat /dev/zero" as the third distinct name, reading endless zero
    // bytes instead of hitting EOF on /dev/null - confirmed simpler and
    // reliably single-threaded, unlike "tail -f /dev/null", which turned
    // out to spawn an inotify-watcher thread whose exact name is not
    // something this test can predict or should be comparing on.
    //
    // Spawned in alphabetical order (cat, sleep, yes) deliberately:
    // real pstree sorts children by name, nshbox enumerates /proc in
    // whatever order the kernel returns (normally creation order) - a
    // real, separate behavior gap from today's box-drawing fix, out of
    // scope for this pass the same way sibling-merging is (see the file
    // comment above). Matching spawn order to alphabetical order here
    // sidesteps it rather than silently depending on it.
    BackgroundProcess proc("sh", {"-c", "cat /dev/zero >/dev/null & sleep 60 & yes >/dev/null & wait"});
    settle();

    ASSERT_EQ(run_nshbox_pstree(proc.pid()), run_real_pstree(proc.pid()),
              "pstree with three children");
}
