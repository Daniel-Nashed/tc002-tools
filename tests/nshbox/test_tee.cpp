// Compares nshbox's tee against real tee(1) - both copy stdin to stdout
// and to each named file (see cmd_tee() in nshbox/src/nshbox.c).
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;
using nshtest::read_file;

TEST_CASE(TeeCopiesToStdoutAndFile, "tee: copies stdin to stdout and to a file")
{
    TempDir dir;
    std::string input = "line one\nline two\nline three\n";
    std::string real_out_path = dir.child("real_out.txt");
    std::string nshbox_out_path = dir.child("nshbox_out.txt");

    auto expected = run_command("tee", {real_out_path}, input);
    auto actual = run_command(nshbox_path(), {"tee", nshbox_out_path}, input);

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "tee's own stdout copy");
    ASSERT_EQ(read_file(nshbox_out_path), read_file(real_out_path), "tee's file copy");
    ASSERT_EQ(read_file(nshbox_out_path), input, "tee's file copy matches the original input exactly");
}

TEST_CASE(TeeAppendFlag, "tee: -a appends instead of truncating")
{
    TempDir dir;
    std::string path = dir.write_file("out.txt", "existing content\n");

    run_command(nshbox_path(), {"tee", "-a", path}, "appended content\n");

    ASSERT_EQ(read_file(path), "existing content\nappended content\n", "tee -a appended rather than truncated");
}

TEST_CASE(TeeWithoutAppendTruncates, "tee: without -a, truncates existing content first")
{
    TempDir dir;
    std::string path = dir.write_file("out.txt", "this should be gone\n");

    run_command(nshbox_path(), {"tee", path}, "new content\n");

    ASSERT_EQ(read_file(path), "new content\n", "tee without -a truncated the existing content");
}

TEST_CASE(TeeMultipleFiles, "tee: writes to more than one file at once")
{
    TempDir dir;
    std::string input = "shared content\n";
    std::string path_a = dir.child("a.txt");
    std::string path_b = dir.child("b.txt");

    run_command(nshbox_path(), {"tee", path_a, path_b}, input);

    ASSERT_EQ(read_file(path_a), input, "tee's first output file");
    ASSERT_EQ(read_file(path_b), input, "tee's second output file");
}
