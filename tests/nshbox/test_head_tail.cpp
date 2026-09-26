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

// ---------------------------------------------------------------------
// The GNU option spellings beyond plain "-n N": -N, -nN, --lines=, -c,
// tail's +N, and the "==> file <==" headers for several files. Each case
// runs the real tool and nshbox with the identical arguments and compares
// stdout and the exit code.
// ---------------------------------------------------------------------

namespace {

void expect_same(const std::string &tool, const std::vector<std::string> &opts,
                 const std::vector<std::string> &files, const std::string &stdin_data = "")
{
    std::vector<std::string> args = opts;
    args.insert(args.end(), files.begin(), files.end());

    std::vector<std::string> nsh_args = {tool};
    nsh_args.insert(nsh_args.end(), args.begin(), args.end());

    auto expected = run_command(tool, args, stdin_data);
    auto actual = run_command(nshbox_path(), nsh_args, stdin_data);

    std::string context = tool;

    for (const auto &o : opts)
        context += " " + o;

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, context);
    ASSERT_TRUE(actual.exit_code == expected.exit_code, context + ": exit code");
}

} // namespace

TEST_CASE(HeadOptionSpellings, "head: -N, -nN, --lines=N, -c N, -cN, --bytes=N")
{
    TempDir dir;
    // No trailing newline on purpose: the byte counts cut through a line.
    std::string path = dir.write_file("f.txt", make_numbered_lines(30) + "last line, no newline");

    expect_same("head", {"-3"}, {path});
    expect_same("head", {"-n3"}, {path});
    expect_same("head", {"--lines=3"}, {path});
    expect_same("head", {"-n", "0"}, {path});
    expect_same("head", {"-c", "10"}, {path});
    expect_same("head", {"-c10"}, {path});
    expect_same("head", {"--bytes=10"}, {path});
    expect_same("head", {"-c", "100000"}, {path});
}

TEST_CASE(TailOptionSpellings, "tail: -N, -nN, --lines=N, -n +N, -c N, -c +N, no trailing newline")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", make_numbered_lines(30) + "last line, no newline");

    expect_same("tail", {"-3"}, {path});
    expect_same("tail", {"-n3"}, {path});
    expect_same("tail", {"--lines=3"}, {path});
    expect_same("tail", {"-n", "-3"}, {path});
    expect_same("tail", {"-n", "+5"}, {path});
    expect_same("tail", {"-n", "+1"}, {path});
    expect_same("tail", {"-n", "+0"}, {path});
    expect_same("tail", {"-n", "+200"}, {path});
    expect_same("tail", {"-c", "10"}, {path});
    expect_same("tail", {"-c10"}, {path});
    expect_same("tail", {"--bytes=10"}, {path});
    expect_same("tail", {"-c", "+10"}, {path});
    expect_same("tail", {"-c", "100000"}, {path});
}

TEST_CASE(TailBytesWrapsRing, "tail: -c across the ring buffer wraparound on a larger file")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", make_numbered_lines(2000));

    expect_same("tail", {"-c", "7"}, {path});
    expect_same("tail", {"-c", "5000"}, {path});
}

TEST_CASE(HeadTailMultipleFileHeaders, "head/tail: ==> file <== headers for several files, -q, -v")
{
    TempDir dir;
    std::string a = dir.write_file("a.txt", make_numbered_lines(5));
    std::string b = dir.write_file("b.txt", make_numbered_lines(8));

    expect_same("head", {"-n", "2"}, {a, b});
    expect_same("head", {"-q", "-n", "2"}, {a, b});
    expect_same("head", {"-v", "-n", "2"}, {a});
    expect_same("tail", {"-n", "2"}, {a, b});
    expect_same("tail", {"-q", "-n", "2"}, {a, b});
    expect_same("tail", {"-v", "-n", "2"}, {a});
}

TEST_CASE(HeadTailMissingFileAmongMany, "head/tail: a missing file reports an error and the rest are still shown")
{
    TempDir dir;
    std::string a = dir.write_file("a.txt", make_numbered_lines(5));
    std::string b = dir.write_file("b.txt", make_numbered_lines(5));
    std::string missing = dir.path() + "/does-not-exist";

    expect_same("head", {"-n", "1"}, {a, missing, b});
    expect_same("tail", {"-n", "1"}, {a, missing, b});
}

TEST_CASE(HeadTailStdin, "head/tail: stdin with no file and with -")
{
    std::string data = make_numbered_lines(30);

    expect_same("head", {"-3"}, {}, data);
    expect_same("tail", {"-3"}, {}, data);
    expect_same("head", {"-n", "2"}, {"-"}, data);
    expect_same("tail", {"-n", "+29"}, {"-"}, data);
}

TEST_CASE(HeadTailBadOptions, "head/tail: an unknown option or a bad number is a usage error")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", make_numbered_lines(3));

    for (const char *tool : {"head", "tail"}) {
        auto a = run_command(nshbox_path(), {tool, "-n", "abc", path});
        auto b = run_command(nshbox_path(), {tool, "-z", path});
        auto c = run_command(nshbox_path(), {tool, "-n"});

        ASSERT_TRUE(a.exit_code == 1, std::string(tool) + " -n abc");
        ASSERT_TRUE(b.exit_code == 1, std::string(tool) + " -z");
        ASSERT_TRUE(c.exit_code == 1, std::string(tool) + " -n with no value");
        ASSERT_TRUE(a.stderr_data.find("Usage: nshbox ") != std::string::npos, "usage message");
    }
}
