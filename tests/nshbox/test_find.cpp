// Compares nshbox's find against real GNU findutils find(1). Both walk
// the exact same on-disk tree via readdir() (see find_walk() in
// nshbox/src/nshbox.c), which returns entries in a stable but
// unspecified order - comparing sorted line sets rather than raw output
// removes any dependency on that order matching between the two separate
// process invocations, instead of just hoping it does.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"
#include "text_utils.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;
using nshtest::sorted_lines;
using nshtest::join_lines;

namespace {

TempDir make_sample_tree()
{
    TempDir dir;

    run_command("mkdir", {"-p", dir.child("a/b")});
    dir.write_file("top.txt", "x");
    dir.write_file("a/one.txt", "x");
    dir.write_file("a/two.log", "x");
    dir.write_file("a/b/deep.txt", "x");

    return dir;
}

} // namespace

TEST_CASE(FindAllEntries, "find: lists every entry under a tree")
{
    TempDir dir = make_sample_tree();

    auto expected = run_command("find", {dir.path()});
    auto actual = run_command(nshbox_path(), {"find", dir.path()});

    ASSERT_EQ(join_lines(sorted_lines(actual.stdout_data)),
              join_lines(sorted_lines(expected.stdout_data)),
              "find with no filters");
}

TEST_CASE(FindByNamePattern, "find: -name filters by glob pattern")
{
    TempDir dir = make_sample_tree();

    auto expected = run_command("find", {dir.path(), "-name", "*.txt"});
    auto actual = run_command(nshbox_path(), {"find", dir.path(), "-name", "*.txt"});

    ASSERT_EQ(join_lines(sorted_lines(actual.stdout_data)),
              join_lines(sorted_lines(expected.stdout_data)),
              "find -name *.txt");
}

TEST_CASE(FindByTypeDirectory, "find: -type d filters to directories only")
{
    TempDir dir = make_sample_tree();

    auto expected = run_command("find", {dir.path(), "-type", "d"});
    auto actual = run_command(nshbox_path(), {"find", dir.path(), "-type", "d"});

    ASSERT_EQ(join_lines(sorted_lines(actual.stdout_data)),
              join_lines(sorted_lines(expected.stdout_data)),
              "find -type d");
}

TEST_CASE(FindByTypeFile, "find: -type f filters to regular files only")
{
    TempDir dir = make_sample_tree();

    auto expected = run_command("find", {dir.path(), "-type", "f"});
    auto actual = run_command(nshbox_path(), {"find", dir.path(), "-type", "f"});

    ASSERT_EQ(join_lines(sorted_lines(actual.stdout_data)),
              join_lines(sorted_lines(expected.stdout_data)),
              "find -type f");
}

TEST_CASE(FindMaxdepth, "find: -maxdepth 1 stops at immediate children")
{
    TempDir dir = make_sample_tree();

    auto expected = run_command("find", {dir.path(), "-maxdepth", "1"});
    auto actual = run_command(nshbox_path(), {"find", dir.path(), "-maxdepth", "1"});

    ASSERT_EQ(join_lines(sorted_lines(actual.stdout_data)),
              join_lines(sorted_lines(expected.stdout_data)),
              "find -maxdepth 1");
}
