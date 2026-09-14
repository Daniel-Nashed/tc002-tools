// Compares nshbox's head/tail against real GNU coreutils head(1)/tail(1).
// tail in particular is worth covering here: nshbox's own README
// describes it as "fixed-size ring buffer" (see nshbox/src/nshbox.c) -
// exactly the kind of implementation detail that is easy to get subtly
// wrong (off-by-one on the wrap point, stale data left in the buffer),
// so it is diffed against the real tool rather than trusted by inspection.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

namespace {

std::string make_numbered_lines(int count)
{
    std::string content;

    for (int i = 1; i <= count; i++)
        content += "line " + std::to_string(i) + "\n";

    return content;
}

} // namespace

TEST_CASE(HeadDefault, "head: default first 10 lines")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", make_numbered_lines(25));

    auto expected = run_command("head", {path});
    auto actual = run_command(nshbox_path(), {"head", path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "head default -n 10");
}

TEST_CASE(HeadCustomCount, "head: -n 3")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", make_numbered_lines(25));

    auto expected = run_command("head", {"-n", "3", path});
    auto actual = run_command(nshbox_path(), {"head", "-n", "3", path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "head -n 3");
}

TEST_CASE(HeadFewerLinesThanRequested, "head: file shorter than -n")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", make_numbered_lines(3));

    auto expected = run_command("head", {"-n", "10", path});
    auto actual = run_command(nshbox_path(), {"head", "-n", "10", path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "head -n 10 on a 3-line file");
}

TEST_CASE(TailDefault, "tail: default last 10 lines")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", make_numbered_lines(25));

    auto expected = run_command("tail", {path});
    auto actual = run_command(nshbox_path(), {"tail", path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "tail default -n 10");
}

TEST_CASE(TailCustomCount, "tail: -n 3, exercising the ring buffer's wraparound")
{
    TempDir dir;
    // More lines than the default window, so the ring buffer this
    // exercises has definitely wrapped at least once by the end.
    std::string path = dir.write_file("f.txt", make_numbered_lines(100));

    auto expected = run_command("tail", {"-n", "3", path});
    auto actual = run_command(nshbox_path(), {"tail", "-n", "3", path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "tail -n 3 after 100 lines");
}

TEST_CASE(TailFewerLinesThanRequested, "tail: file shorter than -n")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", make_numbered_lines(3));

    auto expected = run_command("tail", {"-n", "10", path});
    auto actual = run_command(nshbox_path(), {"tail", "-n", "10", path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "tail -n 10 on a 3-line file");
}
