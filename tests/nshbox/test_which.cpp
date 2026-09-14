// Compares nshbox's which against real which(1) - both just search $PATH
// for an executable (see cmd_which() in nshbox/src/nshbox.c).
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

TEST_CASE(WhichFindsRealCommand, "which: locates a real command on PATH")
{
    auto expected = run_command("which", {"ls"});
    auto actual = run_command(nshbox_path(), {"which", "ls"});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "which ls");
}

TEST_CASE(WhichNonexistentCommand, "which: a command that does not exist anywhere on PATH")
{
    auto expected = run_command("which", {"this-command-does-not-exist-anywhere-12345"});
    auto actual = run_command(nshbox_path(), {"which", "this-command-does-not-exist-anywhere-12345"});

    // Neither tool is expected to print anything for a miss - only the
    // (nonzero, but not otherwise asserted here) exit code differs from
    // the found case.
    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "which on a nonexistent command");
}

TEST_CASE(WhichWithSlashInName, "which: a name containing '/' is checked directly, not searched on PATH")
{
    TempDir dir;
    std::string path = dir.write_file("myscript.sh", "#!/bin/sh\necho hi\n");

    run_command("chmod", {"+x", path});

    auto expected = run_command("which", {path});
    auto actual = run_command(nshbox_path(), {"which", path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "which on a path containing '/'");
}
