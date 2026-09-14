// Compares nshbox's du against real GNU coreutils du(1). Uses -b
// (apparent size, exact byte count - see du_path() in
// nshbox/src/nshbox.c) on both sides deliberately: du's *default* output
// is disk usage in filesystem blocks, which depends on the underlying
// filesystem's own block size and is not reproducibly comparable between
// two independent calls the way a plain byte count is. Sorted line
// comparison for the multi-entry cases, same reasoning as test_find.cpp -
// both walk the same tree via readdir(), whose order is not a contract
// either tool makes.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"
#include "text_utils.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;
using nshtest::sorted_lines;
using nshtest::join_lines;

TEST_CASE(DuSingleFileSummary, "du: -sb on a single file")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "exactly 17 bytes\n");

    auto expected = run_command("du", {"-sb", path});
    auto actual = run_command(nshbox_path(), {"du", "-sb", path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "du -sb on a single file");
}

TEST_CASE(DuDirectorySummary, "du: -sb summary on a directory tree")
{
    TempDir dir;

    run_command("mkdir", {"-p", dir.child("sub")});
    dir.write_file("a.txt", "12345");
    dir.write_file("sub/b.txt", "1234567890");

    auto expected = run_command("du", {"-sb", dir.path()});
    auto actual = run_command(nshbox_path(), {"du", "-sb", dir.path()});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "du -sb on a directory tree");
}

TEST_CASE(DuRecursivePerDirectory, "du: -b without -s lists every subdirectory")
{
    TempDir dir;

    run_command("mkdir", {"-p", dir.child("sub/deeper")});
    dir.write_file("a.txt", "12345");
    dir.write_file("sub/b.txt", "1234567890");
    dir.write_file("sub/deeper/c.txt", "123");

    auto expected = run_command("du", {"-b", dir.path()});
    auto actual = run_command(nshbox_path(), {"du", "-b", dir.path()});

    ASSERT_EQ(join_lines(sorted_lines(actual.stdout_data)),
              join_lines(sorted_lines(expected.stdout_data)),
              "du -b recursive per-directory listing");
}

TEST_CASE(DuEmptyDirectory, "du: -sb on an empty directory")
{
    TempDir dir;

    auto expected = run_command("du", {"-sb", dir.path()});
    auto actual = run_command(nshbox_path(), {"du", "-sb", dir.path()});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "du -sb on an empty directory");
}
