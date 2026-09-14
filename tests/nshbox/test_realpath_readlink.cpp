// Compares nshbox's realpath/readlink against real GNU coreutils
// realpath(1)/readlink(1). Both are thin wrappers around the same libc
// calls (realpath(3)/readlink(2) - see cmd_realpath()/cmd_readlink() in
// nshbox/src/nshbox.c), so any mismatch here would mean nshbox's own
// argument handling is wrong, not the underlying resolution logic.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

TEST_CASE(RealpathPlainFile, "realpath: a plain existing file")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "content\n");

    auto expected = run_command("realpath", {path});
    auto actual = run_command(nshbox_path(), {"realpath", path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "realpath on a plain file");
}

TEST_CASE(RealpathThroughSymlink, "realpath: resolves through a symlink")
{
    TempDir dir;
    std::string target = dir.write_file("real.txt", "content\n");
    std::string link = dir.child("link.txt");

    run_command("ln", {"-s", target, link});

    auto expected = run_command("realpath", {link});
    auto actual = run_command(nshbox_path(), {"realpath", link});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "realpath through a symlink");
}

TEST_CASE(RealpathRelativeDotDot, "realpath: collapses '..' components")
{
    TempDir dir;
    std::string sub = dir.child("sub");

    run_command("mkdir", {sub});

    std::string messy_path = sub + "/../real.txt";
    dir.write_file("real.txt", "content\n");

    auto expected = run_command("realpath", {messy_path});
    auto actual = run_command(nshbox_path(), {"realpath", messy_path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "realpath collapsing '..'");
}

TEST_CASE(ReadlinkPlainTarget, "readlink: immediate target, no -f")
{
    TempDir dir;
    std::string target = dir.child("real.txt");
    std::string link = dir.child("link.txt");

    run_command("ln", {"-s", target, link});

    auto expected = run_command("readlink", {link});
    auto actual = run_command(nshbox_path(), {"readlink", link});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "readlink plain (immediate target)");
}

TEST_CASE(ReadlinkCanonicalFollowsChain, "readlink: -f follows a chain of symlinks")
{
    TempDir dir;
    std::string real_file = dir.write_file("real.txt", "content\n");
    std::string link_a = dir.child("a.txt");
    std::string link_b = dir.child("b.txt");

    // b -> a -> real.txt - a genuine chain, not a single hop, so this
    // actually exercises "follow more than once" rather than "follow".
    run_command("ln", {"-s", real_file, link_a});
    run_command("ln", {"-s", link_a, link_b});

    auto expected = run_command("readlink", {"-f", link_b});
    auto actual = run_command(nshbox_path(), {"readlink", "-f", link_b});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "readlink -f through a symlink chain");
}
