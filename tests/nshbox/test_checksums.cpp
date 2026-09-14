// Compares nshbox's sha256sum/sha1sum/sha384sum/sha512sum/md5sum against
// real GNU coreutils - the highest-value commands to get right here:
// nshbox's own README documents these as "coreutils-output-compatible"
// specifically, and a silently wrong checksum is a genuinely bad failure
// mode for an integrity-checking tool, unlike most of what else nshbox
// does. All five share one hash_main() implementation in nshbox.c
// (see "No SHA3 commands here" nearby - a real on-device constraint,
// unrelated to this test), so one test file covers all five rather than
// five near-identical ones.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

namespace {

void assert_checksum_matches(const std::string &algo, const std::string &real_tool, const std::string &path)
{
    auto expected = run_command(real_tool, {path});
    auto actual = run_command(nshbox_path(), {algo, path});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, algo + " on a real file");
}

} // namespace

TEST_CASE(Sha256sumMatchesReal, "sha256sum: matches real sha256sum")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "the quick brown fox jumps over the lazy dog\n");

    assert_checksum_matches("sha256sum", "sha256sum", path);
}

TEST_CASE(Sha1sumMatchesReal, "sha1sum: matches real sha1sum")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "the quick brown fox jumps over the lazy dog\n");

    assert_checksum_matches("sha1sum", "sha1sum", path);
}

TEST_CASE(Sha384sumMatchesReal, "sha384sum: matches real sha384sum")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "the quick brown fox jumps over the lazy dog\n");

    assert_checksum_matches("sha384sum", "sha384sum", path);
}

TEST_CASE(Sha512sumMatchesReal, "sha512sum: matches real sha512sum")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "the quick brown fox jumps over the lazy dog\n");

    assert_checksum_matches("sha512sum", "sha512sum", path);
}

TEST_CASE(Md5sumMatchesReal, "md5sum: matches real md5sum")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "the quick brown fox jumps over the lazy dog\n");

    assert_checksum_matches("md5sum", "md5sum", path);
}

TEST_CASE(Sha256sumEmptyFile, "sha256sum: the well-known empty-input hash")
{
    TempDir dir;
    std::string path = dir.write_file("empty.txt", "");

    assert_checksum_matches("sha256sum", "sha256sum", path);
}

TEST_CASE(Sha256sumBinaryContent, "sha256sum: binary content, not just text")
{
    TempDir dir;
    std::string binary_content;

    for (int i = 0; i < 256; i++)
        binary_content += static_cast<char>(i);

    std::string path = dir.write_file("binary.dat", binary_content);

    assert_checksum_matches("sha256sum", "sha256sum", path);
}

TEST_CASE(Sha256sumFromStdin, "sha256sum: reads from stdin when no file is given")
{
    auto expected = run_command("sha256sum", {}, "data via stdin\n");
    auto actual = run_command(nshbox_path(), {"sha256sum"}, "data via stdin\n");

    // Real sha256sum prints "<hash>  -" for stdin; nshbox does the same
    // (hash_main() passes "-" as the display name for the stdin case) -
    // still a raw diff, not special-cased.
    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "sha256sum reading from stdin");
}
