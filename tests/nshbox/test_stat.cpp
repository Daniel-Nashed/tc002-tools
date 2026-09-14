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
