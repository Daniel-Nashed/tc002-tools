// Compares nshbox's stat against real GNU coreutils stat(1) - field by
// field, not a raw diff. nshbox's own output format (see cmd_stat() in
// nshbox/src/nshbox.c) is intentionally its own thing, not GNU stat's
// default text layout, so this extracts specific numbers from each
// side's very differently-formatted output and compares those instead:
// real stat via its own --format=, nshbox's own custom "  Label: value"
// lines via a small line-prefix scan.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

#include <sstream>
#include <stdexcept>

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

namespace {

// Finds a line starting with prefix in nshbox's own stat output and
// returns everything after it, trimmed - e.g. find_field(out, "  Size: ")
// on "  Size: 17\n" returns "17".
std::string find_field(const std::string &output, const std::string &prefix)
{
    std::istringstream stream(output);
    std::string line;

    while (std::getline(stream, line)) {
        if (line.rfind(prefix, 0) == 0)
            return line.substr(prefix.size());
    }

    throw std::runtime_error("nshbox stat output missing expected field: " + prefix);
}

} // namespace

TEST_CASE(StatFieldsMatchRealFile, "stat: size/uid/gid/nlink match real stat's own numbers")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "exactly 17 bytes\n");

    auto nshbox_out = run_command(nshbox_path(), {"stat", path});
    auto real_out = run_command("stat", {"--format=%s %u %g %h", path});

    std::istringstream real_fields(real_out.stdout_data);
    std::string expected_size, expected_uid, expected_gid, expected_nlink;

    real_fields >> expected_size >> expected_uid >> expected_gid >> expected_nlink;

    ASSERT_EQ(find_field(nshbox_out.stdout_data, "  Size: "), expected_size, "stat size field");
    ASSERT_EQ(find_field(nshbox_out.stdout_data, "   UID: "), expected_uid, "stat UID field");
    ASSERT_EQ(find_field(nshbox_out.stdout_data, "   GID: "), expected_gid, "stat GID field");
    ASSERT_EQ(find_field(nshbox_out.stdout_data, " Links: "), expected_nlink, "stat link-count field");
}

TEST_CASE(StatFieldsMatchRealDirectory, "stat: fields match real stat's own numbers for a directory")
{
    TempDir dir;

    auto nshbox_out = run_command(nshbox_path(), {"stat", dir.path()});
    auto real_out = run_command("stat", {"--format=%s %u %g %h", dir.path()});

    std::istringstream real_fields(real_out.stdout_data);
    std::string expected_size, expected_uid, expected_gid, expected_nlink;

    real_fields >> expected_size >> expected_uid >> expected_gid >> expected_nlink;

    ASSERT_EQ(find_field(nshbox_out.stdout_data, "  Size: "), expected_size, "stat size field (directory)");
    ASSERT_EQ(find_field(nshbox_out.stdout_data, "   UID: "), expected_uid, "stat UID field (directory)");
    ASSERT_EQ(find_field(nshbox_out.stdout_data, "   GID: "), expected_gid, "stat GID field (directory)");
    ASSERT_EQ(find_field(nshbox_out.stdout_data, " Links: "), expected_nlink, "stat link-count field (directory)");
}

TEST_CASE(StatModeOctalMatches, "stat: octal permission bits match real stat's own %a")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "x");

    run_command("chmod", {"640", path});

    auto nshbox_out = run_command(nshbox_path(), {"stat", path});
    auto real_out = run_command("stat", {"--format=%a", path});

    std::string expected_mode = real_out.stdout_data;

    if (!expected_mode.empty() && expected_mode.back() == '\n')
        expected_mode.pop_back();

    // nshbox prints "  Mode: 0640 (rw-r-----)" - the octal field is the
    // first whitespace-delimited token after the label, without the
    // leading zero real stat's own %a does not print either.
    std::string mode_line = find_field(nshbox_out.stdout_data, "  Mode: ");
    std::string actual_mode = mode_line.substr(0, mode_line.find(' '));

    // Strip a leading zero from nshbox's "0640" to compare against
    // real stat's "%a", which prints "640" with no leading zero.
    if (actual_mode.size() == 4 && actual_mode[0] == '0')
        actual_mode = actual_mode.substr(1);

    ASSERT_EQ(actual_mode, expected_mode, "stat octal mode bits (chmod 640)");
}

namespace {

// The whole compact "stat --json" line for one path, assembled from real
// stat(1)'s own numbers and real date(1)'s own rendering of the mtime, so
// every field is checked against an independent reference in one exact
// comparison rather than field by field.
std::string expected_stat_json(const std::string &path, const std::string &type,
                               const std::string &octal_mode, const std::string &mode_string)
{
    auto real_out = run_command("stat", {"--format=%s %u %g %h %Y", path});
    std::istringstream fields(real_out.stdout_data);
    std::string size, uid, gid, links, mtime_epoch;

    fields >> size >> uid >> gid >> links >> mtime_epoch;

    std::string mtime = run_command("date", {"-d", "@" + mtime_epoch, "+%Y-%m-%d %H:%M:%S %z"}).stdout_data;

    if (!mtime.empty() && mtime.back() == '\n')
        mtime.pop_back();

    return "[{\"file\":\"" + path + "\",\"type\":\"" + type + "\",\"size\":" + size +
           ",\"mode\":\"" + octal_mode + "\",\"mode_string\":\"" + mode_string +
           "\",\"uid\":" + uid + ",\"gid\":" + gid + ",\"links\":" + links +
           ",\"mtime\":\"" + mtime + "\",\"mtime_epoch\":" + mtime_epoch + "}]\n";
}

} // namespace

TEST_CASE(StatJsonRegularFile, "stat --json: every field of a regular file matches real stat/date")
{
    TempDir dir;
    std::string path = dir.write_file("f.txt", "exactly 17 bytes\n");

    run_command("chmod", {"640", path});

    auto actual = run_command(nshbox_path(), {"stat", "--json", path});

    ASSERT_EQ(actual.stdout_data, expected_stat_json(path, "file", "0640", "-rw-r-----"),
              "stat --json on a regular file");
    ASSERT_TRUE(actual.exit_code == 0, "stat --json must exit 0");
}

TEST_CASE(StatJsonDirectory, "stat --json: a directory reports type directory")
{
    TempDir dir;

    run_command("chmod", {"750", dir.path()});

    auto actual = run_command(nshbox_path(), {"stat", "--json", dir.path()});

    ASSERT_EQ(actual.stdout_data, expected_stat_json(dir.path(), "directory", "0750", "drwxr-x---"),
              "stat --json on a directory");
}

TEST_CASE(StatJsonSymlinkNotFollowed, "stat --json: a symlink is described as itself (lstat), not its target")
{
    TempDir dir;
    std::string target = dir.write_file("target.txt", "x");
    std::string link = dir.child("link");

    run_command("ln", {"-s", target, link});

    auto actual = run_command(nshbox_path(), {"stat", "--json", link});

    ASSERT_TRUE(actual.stdout_data.find("\"type\":\"symlink\",") != std::string::npos,
                "type is symlink, not file");
    ASSERT_TRUE(actual.stdout_data.find("\"mode_string\":\"lrwxrwxrwx\",") != std::string::npos,
                "mode_string starts with 'l'");
}

TEST_CASE(StatJsonMultipleFilesFlagAnywhere, "stat --json: several files give one array, flag position does not matter")
{
    TempDir dir;
    std::string first = dir.write_file("a.txt", "a");
    std::string second = dir.write_file("b.txt", "bb");

    auto actual = run_command(nshbox_path(), {"stat", first, "--json", second});

    // Default umask differs between environments, so only assert on the
    // mode-independent shape: two objects, in argument order.
    size_t pos_a = actual.stdout_data.find("\"file\":\"" + first + "\"");
    size_t pos_b = actual.stdout_data.find("\"file\":\"" + second + "\"");

    ASSERT_TRUE(pos_a != std::string::npos && pos_b != std::string::npos, "both files are present");
    ASSERT_TRUE(pos_a < pos_b, "entries keep argument order");
    ASSERT_TRUE(actual.stdout_data.find("},{\"file\":") != std::string::npos, "entries are comma-separated");
    ASSERT_TRUE(actual.stdout_data.rfind("[{", 0) == 0, "output starts as a JSON array");
}

TEST_CASE(StatJsonMissingFile, "stat --json: a missing file is left out, exit code is non-zero, stdout stays valid")
{
    TempDir dir;
    std::string good = dir.write_file("good.txt", "x");

    auto only_missing = run_command(nshbox_path(), {"stat", "--json", dir.child("nope")});

    ASSERT_EQ(only_missing.stdout_data, "[]\n", "no readable file gives an empty array");
    ASSERT_TRUE(only_missing.exit_code != 0, "a missing file must fail");

    auto mixed = run_command(nshbox_path(), {"stat", "--json", dir.child("nope"), good});

    ASSERT_TRUE(mixed.stdout_data.find("\"file\":\"" + good + "\"") != std::string::npos,
                "the readable file is still reported");
    ASSERT_TRUE(mixed.stdout_data.find("nope") == std::string::npos, "the missing file has no entry");
    ASSERT_TRUE(mixed.exit_code != 0, "a missing file must still fail the whole command");
}

TEST_CASE(StatJsonNeedsAFile, "stat --json: --json alone is a usage error")
{
    auto actual = run_command(nshbox_path(), {"stat", "--json"});

    ASSERT_TRUE(actual.exit_code != 0, "no file argument must fail");
    ASSERT_EQ(actual.stdout_data, "", "nothing on stdout for a usage error");
}
