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

namespace {

// Real tool's own digest for a path - the first token of "<hash>  <path>".
std::string real_digest(const std::string &real_tool, const std::string &path)
{
    std::string out = run_command(real_tool, {path}).stdout_data;

    return out.substr(0, out.find(' '));
}

std::string json_entry(const std::string &path, const std::string &algorithm, const std::string &digest)
{
    return "{\"file\":\"" + path + "\",\"algorithm\":\"" + algorithm + "\",\"digest\":\"" + digest + "\"}";
}

void assert_json_matches(const std::string &command, const std::string &algorithm, const std::string &path)
{
    auto actual = run_command(nshbox_path(), {command, "--json", path});

    ASSERT_EQ(actual.stdout_data, "[" + json_entry(path, algorithm, real_digest(command, path)) + "]\n",
              command + " --json on a real file");
    ASSERT_TRUE(actual.exit_code == 0, command + " --json must exit 0");
}

} // namespace

TEST_CASE(ChecksumJsonMatchesRealTools, "checksums --json: all five commands match the real tools' digests")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "the quick brown fox jumps over the lazy dog\n");

    assert_json_matches("sha256sum", "sha256", path);
    assert_json_matches("sha1sum", "sha1", path);
    assert_json_matches("sha384sum", "sha384", path);
    assert_json_matches("sha512sum", "sha512", path);
    assert_json_matches("md5sum", "md5", path);
}

TEST_CASE(Sha256sumJsonKnownVector, "sha256sum --json: the published SHA-256 test vector for \"abc\"")
{
    // Independent of any tool on the machine: FIPS 180-2's own example.
    TempDir dir;
    std::string path = dir.write_file("abc.txt", "abc");

    auto actual = run_command(nshbox_path(), {"sha256sum", "--json", path});

    ASSERT_EQ(actual.stdout_data,
              "[" + json_entry(path, "sha256",
                               "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") + "]\n",
              "sha256sum --json of \"abc\"");
}

TEST_CASE(ChecksumJsonMultipleFiles, "sha256sum --json: several files give one array in argument order")
{
    TempDir dir;
    std::string first = dir.write_file("a.txt", "first\n");
    std::string second = dir.write_file("b.txt", "second\n");

    // --json deliberately between the files: position must not matter.
    auto actual = run_command(nshbox_path(), {"sha256sum", first, "--json", second});

    ASSERT_EQ(actual.stdout_data,
              "[" + json_entry(first, "sha256", real_digest("sha256sum", first)) + "," +
                  json_entry(second, "sha256", real_digest("sha256sum", second)) + "]\n",
              "sha256sum --json over two files");
}

TEST_CASE(ChecksumJsonFromStdin, "sha256sum --json: no file argument reads stdin, reported as \"-\"")
{
    auto actual = run_command(nshbox_path(), {"sha256sum", "--json"}, "abc");

    ASSERT_EQ(actual.stdout_data,
              "[" + json_entry("-", "sha256",
                               "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") + "]\n",
              "sha256sum --json reading stdin");
}

TEST_CASE(ChecksumJsonMissingFile, "sha256sum --json: a missing file is left out, exit code is non-zero, stdout stays valid")
{
    TempDir dir;
    std::string good = dir.write_file("good.txt", "x");
    std::string missing = dir.child("nope");

    auto only_missing = run_command(nshbox_path(), {"sha256sum", "--json", missing});

    ASSERT_EQ(only_missing.stdout_data, "[]\n", "no readable file gives an empty array");
    ASSERT_TRUE(only_missing.exit_code != 0, "a missing file must fail");

    auto mixed = run_command(nshbox_path(), {"sha256sum", "--json", missing, good});

    ASSERT_EQ(mixed.stdout_data, "[" + json_entry(good, "sha256", real_digest("sha256sum", good)) + "]\n",
              "the readable file is still reported, without a leading comma");
    ASSERT_TRUE(mixed.exit_code != 0, "a missing file must still fail the whole command");
}

TEST_CASE(ChecksumJsonEscapesFileName, "sha256sum --json: a file name needing JSON escaping is escaped")
{
    TempDir dir;
    std::string path = dir.write_file("with\"quote.txt", "x");

    auto actual = run_command(nshbox_path(), {"sha256sum", "--json", path});

    ASSERT_TRUE(actual.stdout_data.find("with\\\"quote.txt") != std::string::npos,
                "the double quote in the name is backslash-escaped");
    ASSERT_TRUE(actual.exit_code == 0, "sha256sum --json must exit 0");
}

TEST_CASE(ChecksumJsonPretty, "sha256sum --JSON: pretty-printed")
{
    TempDir dir;
    std::string path = dir.write_file("abc.txt", "abc");

    auto actual = run_command(nshbox_path(), {"sha256sum", "--JSON", path});

    ASSERT_EQ(actual.stdout_data,
              "[\n"
              "  {\n"
              "    \"file\": \"" + path + "\",\n"
              "    \"algorithm\": \"sha256\",\n"
              "    \"digest\": \"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"\n"
              "  }\n"
              "]\n",
              "sha256sum --JSON of \"abc\"");
}
