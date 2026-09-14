// Compares nshbox's wc against real GNU coreutils wc(1). nshbox's own
// counting logic (see wc_stream() in nshbox/src/nshbox.c) is hand-rolled,
// so this checks it actually agrees with the real tool on line/word/byte
// counts, including the classic off-by-one edge case of a file with no
// trailing newline on its last line.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

#include <sstream>

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

namespace {

struct WcCounts
{
    long lines = -1;
    long words = -1;
    long bytes = -1;
};

// Real wc right-pads/aligns its columns with the filename; nshbox's own
// README documents its own output as plain counts, not byte-identical
// column alignment - so every comparison here extracts the numbers from
// each side rather than diffing the raw output lines.
WcCounts parse_counts(const std::string &output)
{
    std::istringstream stream(output);
    WcCounts counts;

    stream >> counts.lines >> counts.words >> counts.bytes;
    return counts;
}

} // namespace

TEST_CASE(WcDefaultCounts, "wc: default -lwc counts on a normal file")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "one two three\nfour five\nsix\n");

    auto expected = parse_counts(run_command("wc", {path}).stdout_data);
    auto actual = parse_counts(run_command(nshbox_path(), {"wc", path}).stdout_data);

    ASSERT_EQ(std::to_string(actual.lines), std::to_string(expected.lines), "wc line count");
    ASSERT_EQ(std::to_string(actual.words), std::to_string(expected.words), "wc word count");
    ASSERT_EQ(std::to_string(actual.bytes), std::to_string(expected.bytes), "wc byte count");
}

TEST_CASE(WcNoTrailingNewline, "wc: last line has no trailing newline")
{
    TempDir dir;
    // Deliberately no trailing "\n" on the last line - the classic
    // off-by-one case for a hand-rolled line counter.
    std::string path = dir.write_file("f.txt", "line one\nline two\nline three");

    auto expected = parse_counts(run_command("wc", {"-l", path}).stdout_data);
    auto actual = parse_counts(run_command(nshbox_path(), {"wc", "-l", path}).stdout_data);

    ASSERT_EQ(std::to_string(actual.lines), std::to_string(expected.lines),
              "wc -l line count with no trailing newline on the last line");
}

TEST_CASE(WcEmptyFile, "wc: empty file")
{
    TempDir dir;
    std::string path = dir.write_file("empty.txt", "");

    auto expected = parse_counts(run_command("wc", {path}).stdout_data);
    auto actual = parse_counts(run_command(nshbox_path(), {"wc", path}).stdout_data);

    ASSERT_EQ(std::to_string(actual.lines), std::to_string(expected.lines), "wc line count (empty file)");
    ASSERT_EQ(std::to_string(actual.words), std::to_string(expected.words), "wc word count (empty file)");
    ASSERT_EQ(std::to_string(actual.bytes), std::to_string(expected.bytes), "wc byte count (empty file)");
}
