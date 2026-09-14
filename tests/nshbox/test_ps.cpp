// Compares nshbox's ps against real ps(1) and against itself, rooted at
// a single known, controlled process (BackgroundProcess) rather than the
// container's own full, constantly-changing process table - the same
// technique test_pstree.cpp already uses to sidestep the "two
// independent snapshots of a live system never quite match" problem.
// This does NOT diff the whole listing (there is no meaningful reference
// for that), but it does get a real, narrow diff for the one row that
// matters: PPID and the full command line, cross-checked against
// "ps -p <pid> -o ppid=,args=" for that exact PID.
#include "framework.hpp"
#include "run_command.hpp"
#include "background_process.hpp"

#include <sstream>
#include <stdexcept>
#include <string>

#include <time.h>

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::BackgroundProcess;

namespace {

void settle()
{
    struct timespec delay = {0, 200 * 1000 * 1000}; // 200ms
    nanosleep(&delay, nullptr);
}

// Finds the flat JSON object for one pid in nshbox's own "ps --json"
// array output (e.g. {"pid":123,"ppid":1,...,"command":"sleep 77"}) and
// returns it as a raw substring. Nothing in this project's own JSON
// output ever nests objects (see json_print_string() in nshbox.c), so a
// plain "find the closing brace" scan is enough - the same lightweight
// approach install/discover_device.sh's own json_field() already uses
// for this project's other flat JSON output, not a general parser.
std::string find_json_object(const std::string &json_array, pid_t pid)
{
    std::string marker = "{\"pid\":" + std::to_string(pid) + ",";
    size_t start = json_array.find(marker);

    if (start == std::string::npos)
        throw std::runtime_error("pid " + std::to_string(pid) + " not found in ps --json output");

    size_t end = json_array.find('}', start);

    if (end == std::string::npos)
        throw std::runtime_error("malformed ps --json output: no closing brace found");

    return json_array.substr(start, end - start + 1);
}

// Extracts a numeric field's value from a flat JSON object substring,
// e.g. field_value(obj, "\"ppid\":") on {"pid":1,"ppid":2,...} -> "2".
std::string numeric_field(const std::string &object, const std::string &key)
{
    size_t pos = object.find(key);

    if (pos == std::string::npos)
        throw std::runtime_error("field not found in ps --json object: " + key);

    pos += key.size();
    size_t end = object.find_first_of(",}", pos);

    return object.substr(pos, end - pos);
}

// Extracts a string field's value, e.g. string_field(obj, "\"command\":")
// on {..., "command":"sleep 77"} -> "sleep 77" (quotes stripped, no
// escape-sequence decoding - none of this test's fixtures need it).
std::string string_field(const std::string &object, const std::string &key)
{
    size_t pos = object.find(key);

    if (pos == std::string::npos)
        throw std::runtime_error("field not found in ps --json object: " + key);

    pos += key.size() + 1; // +1 skips the opening quote
    size_t end = object.find('"', pos);

    return object.substr(pos, end - pos);
}

} // namespace

TEST_CASE(PsJsonFieldsMatchRealPs, "ps --json: a known process's ppid/command match real ps")
{
    BackgroundProcess proc("sleep", {"77"});
    settle();

    auto nshbox_json = run_command(nshbox_path(), {"ps", "--json"}).stdout_data;
    std::string object = find_json_object(nshbox_json, proc.pid());

    std::string real_out = run_command("ps", {"-p", std::to_string(proc.pid()), "-o", "ppid=,args="}).stdout_data;
    std::istringstream real_stream(real_out);
    std::string expected_ppid;
    std::string expected_args;

    real_stream >> expected_ppid;
    std::getline(real_stream, expected_args);

    // ps right-pads/columns "-o ppid=,args=" with leading whitespace
    // before args - trim it rather than assuming an exact single space.
    size_t first_non_space = expected_args.find_first_not_of(' ');
    if (first_non_space != std::string::npos)
        expected_args = expected_args.substr(first_non_space);

    ASSERT_EQ(numeric_field(object, "\"ppid\":"), expected_ppid, "ps --json ppid matches real ps");
    ASSERT_EQ(string_field(object, "\"command\":"), expected_args, "ps --json command matches real ps's own args");
    ASSERT_EQ(string_field(object, "\"command\":"), "sleep 77", "ps --json command is the full command line, not just the short name");
}

TEST_CASE(PsJsonRssBytesMatchesKb, "ps --json: rss_bytes is exactly rss_kb * 1024, not a separately-computed value")
{
    BackgroundProcess proc("sleep", {"78"});
    settle();

    auto nshbox_json = run_command(nshbox_path(), {"ps", "--json"}).stdout_data;
    std::string object = find_json_object(nshbox_json, proc.pid());

    long long rss_kb = std::stoll(numeric_field(object, "\"rss_kb\":"));
    long long rss_bytes = std::stoll(numeric_field(object, "\"rss_bytes\":"));

    ASSERT_EQ(std::to_string(rss_bytes), std::to_string(rss_kb * 1024), "rss_bytes == rss_kb * 1024");
}

TEST_CASE(PsPlainListsKnownProcess, "ps: plain (non-JSON) output includes a known process's full command line")
{
    BackgroundProcess proc("sleep", {"79"});
    settle();

    auto plain_out = run_command(nshbox_path(), {"ps"}).stdout_data;

    ASSERT_TRUE(plain_out.find(std::to_string(proc.pid())) != std::string::npos,
                "ps plain output contains the spawned process's pid");
    ASSERT_TRUE(plain_out.find("sleep 79") != std::string::npos,
                "ps plain output contains the spawned process's full command line");
}

TEST_CASE(PsPlainHeaderMatchesDocumentedFormat, "ps: plain output's header line is exactly what nshbox documents")
{
    auto plain_out = run_command(nshbox_path(), {"ps"}).stdout_data;
    std::string first_line = plain_out.substr(0, plain_out.find('\n'));

    ASSERT_EQ(first_line, "PID     PPID       RSS(kB)  TIME       COMMAND", "ps header line");
}
