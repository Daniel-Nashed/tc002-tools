// Compares nshbox's grep against real GNU grep(1). nshbox's grep uses
// POSIX <regex.h> (see nshbox/src/nshbox.c), the same regex engine GNU
// grep itself builds on, so behavior should match closely for the
// non-GNU-extension subset this harness exercises.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

#include <vector>

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

namespace {

void assert_grep_matches(const std::vector<std::string> &flags_and_pattern, const std::string &path,
                          const std::string &context)
{
    std::vector<std::string> real_args = flags_and_pattern;
    real_args.push_back(path);

    std::vector<std::string> nshbox_args = {"grep"};
    nshbox_args.insert(nshbox_args.end(), flags_and_pattern.begin(), flags_and_pattern.end());
    nshbox_args.push_back(path);

    auto expected = run_command("grep", real_args);
    auto actual = run_command(nshbox_path(), nshbox_args);

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, context);
}

} // namespace

TEST_CASE(GrepBasicMatch, "grep: basic literal match")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "apple\nbanana\ncherry\napricot\n");

    assert_grep_matches({"^a"}, path, "grep ^a");
}

TEST_CASE(GrepCaseInsensitive, "grep: -i case-insensitive")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "Apple\nBANANA\ncherry\n");

    assert_grep_matches({"-i", "apple"}, path, "grep -i apple");
}

TEST_CASE(GrepInvertMatch, "grep: -v invert match")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "keep\nskip\nkeep\nskip\n");

    assert_grep_matches({"-v", "skip"}, path, "grep -v skip");
}

TEST_CASE(GrepCountOnly, "grep: -c count only")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "match\nno\nmatch\nmatch\nno\n");

    assert_grep_matches({"-c", "match"}, path, "grep -c match");
}

TEST_CASE(GrepLineNumbers, "grep: -n line numbers")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "one\ntwo\nthree\ntwo again\n");

    assert_grep_matches({"-n", "two"}, path, "grep -n two");
}

TEST_CASE(GrepExtendedRegex, "grep: -E extended regex alternation")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "cat\ndog\nbird\nfish\n");

    assert_grep_matches({"-E", "cat|dog"}, path, "grep -E cat|dog");
}

TEST_CASE(GrepNoMatches, "grep: no matches at all")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "one\ntwo\nthree\n");

    assert_grep_matches({"nonexistent"}, path, "grep nonexistent (no matches)");
}
