// Compares nshbox's sort against real GNU coreutils sort(1) - byte for
// byte, not just field-by-field, since sort's whole job is producing an
// exact ordering. main.cpp forces LC_ALL=C for the whole harness so
// real sort's collation matches nshbox's own plain strcmp()-based
// comparator (see nshbox/src/nshbox.c - no setlocale()/strcoll() there
// at all).
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

#include <vector>

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

namespace {

void assert_sort_matches(const std::vector<std::string> &nshbox_args,
                          const std::vector<std::string> &real_args,
                          const std::string &context)
{
    auto expected = run_command("sort", real_args);
    auto actual = run_command(nshbox_path(), nshbox_args);

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, context);
}

} // namespace

TEST_CASE(SortDefaultOrder, "sort: default lexicographic order")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "banana\napple\ncherry\napple\n");

    assert_sort_matches({"sort", path}, {path}, "sort default order");
}

TEST_CASE(SortReverse, "sort: -r reverse order")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "banana\napple\ncherry\n");

    assert_sort_matches({"sort", "-r", path}, {"-r", path}, "sort -r reverse order");
}

TEST_CASE(SortNumeric, "sort: -n numeric order")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "10\n2\n33\n4\n");

    assert_sort_matches({"sort", "-n", path}, {"-n", path}, "sort -n numeric order");
}

TEST_CASE(SortUnique, "sort: -u removes duplicates")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "b\na\nb\nc\na\n");

    assert_sort_matches({"sort", "-u", path}, {"-u", path}, "sort -u unique");
}

TEST_CASE(SortCombinedNumericUnique, "sort: -nu combined")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "5\n3\n5\n1\n3\n");

    assert_sort_matches({"sort", "-nu", path}, {"-nu", path}, "sort -nu combined");
}
