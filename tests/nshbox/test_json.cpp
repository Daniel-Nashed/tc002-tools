// Exercises nshbox's own json pretty-printer - see json_pretty_print()/
// cmd_json() in nshbox/src/nshbox.c. No JSON reference tool is guaranteed
// present in this harness's own container (see build/docker-ubuntu's
// Dockerfile), so expected output here is hardcoded rather than diffed
// against one live - each case was independently cross-checked by hand
// against "python3 -m json.tool --indent 2" during development, which
// nshbox's output matched byte-for-byte throughout.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

#include <algorithm>

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

TEST_CASE(JsonPrettyPrintsFlatObject, "json: a flat object with mixed value types")
{
    auto actual = run_command(nshbox_path(), {"json"},
                               R"({"a":1,"b":"two","c":true,"d":false,"e":null})");

    std::string expected =
        "{\n"
        "  \"a\": 1,\n"
        "  \"b\": \"two\",\n"
        "  \"c\": true,\n"
        "  \"d\": false,\n"
        "  \"e\": null\n"
        "}\n";

    ASSERT_EQ(actual.stdout_data, expected, "json pretty-print of a flat object");
    ASSERT_TRUE(actual.exit_code == 0, "well-formed JSON must exit 0");
}

TEST_CASE(JsonPrettyPrintsNestedArrayAndObject, "json: nested array containing an object")
{
    auto actual = run_command(nshbox_path(), {"json"}, R"({"a":1,"b":[1,2,{"c":true}]})");

    std::string expected =
        "{\n"
        "  \"a\": 1,\n"
        "  \"b\": [\n"
        "    1,\n"
        "    2,\n"
        "    {\n"
        "      \"c\": true\n"
        "    }\n"
        "  ]\n"
        "}\n";

    ASSERT_EQ(actual.stdout_data, expected, "json pretty-print of nested array/object");
}

TEST_CASE(JsonEmptyContainersStayInline, "json: empty object/array stay on one line, not '{\\n}'")
{
    auto actual = run_command(nshbox_path(), {"json"}, R"({"empty_obj":{},"empty_arr":[]})");

    std::string expected =
        "{\n"
        "  \"empty_obj\": {},\n"
        "  \"empty_arr\": []\n"
        "}\n";

    ASSERT_EQ(actual.stdout_data, expected, "json pretty-print with empty containers");
}

TEST_CASE(JsonPreservesEscapesInsideStrings, "json: escaped quotes/backslashes inside a string are untouched")
{
    auto actual = run_command(nshbox_path(), {"json"}, R"({"msg":"say \"hi\", a\\b"})");

    std::string expected =
        "{\n"
        "  \"msg\": \"say \\\"hi\\\", a\\\\b\"\n"
        "}\n";

    ASSERT_EQ(actual.stdout_data, expected, "json pretty-print does not reformat string content");
}

TEST_CASE(JsonIgnoresStructuralCharsInsideStrings, "json: braces/commas inside a string do not affect nesting")
{
    // A string containing "}, [" - if the reformatter mistook these for
    // real structure instead of string content, indentation/nesting
    // would come out wrong or the run would report unbalanced brackets.
    auto actual = run_command(nshbox_path(), {"json"}, R"({"a":"}, ["})");

    std::string expected =
        "{\n"
        "  \"a\": \"}, [\"\n"
        "}\n";

    ASSERT_EQ(actual.stdout_data, expected, "json pretty-print treats string content as opaque");
    ASSERT_TRUE(actual.exit_code == 0, "brackets inside a string must not be counted as real structure");
}

TEST_CASE(JsonTopLevelArrayOfObjects, "json: a top-level array of flat objects (this project's own --json shape)")
{
    // The exact shape every --json-emitting command in this project uses
    // (ps/du/find/dig/nslookup): an array of flat objects.
    auto actual = run_command(nshbox_path(), {"json"}, R"([{"path":"/a","bytes":1},{"path":"/b","bytes":2}])");

    std::string expected =
        "[\n"
        "  {\n"
        "    \"path\": \"/a\",\n"
        "    \"bytes\": 1\n"
        "  },\n"
        "  {\n"
        "    \"path\": \"/b\",\n"
        "    \"bytes\": 2\n"
        "  }\n"
        "]\n";

    ASSERT_EQ(actual.stdout_data, expected, "json pretty-print of an array of flat objects");
}

TEST_CASE(JsonWhitespaceInInputIsNormalized, "json: pre-existing whitespace/newlines in the input are ignored")
{
    auto compact = run_command(nshbox_path(), {"json"}, R"({"a":1,"b":2})");
    auto already_spaced = run_command(nshbox_path(), {"json"}, "{\n  \"a\" : 1 ,\n  \"b\":2\n}\n\n");

    ASSERT_EQ(already_spaced.stdout_data, compact.stdout_data,
              "json output must not depend on the input's own whitespace");
}

TEST_CASE(JsonReadsFromFile, "json: reads from a file argument, not just stdin")
{
    TempDir dir;
    std::string path = dir.write_file("data.json", R"({"x":1})");

    auto actual = run_command(nshbox_path(), {"json", path});

    ASSERT_EQ(actual.stdout_data, "{\n  \"x\": 1\n}\n", "json reading from a file argument");
}

TEST_CASE(JsonRejectsUnclosedContainer, "json: unbalanced (missing close) input is a hard error")
{
    auto actual = run_command(nshbox_path(), {"json"}, R"({"a":1)");

    ASSERT_TRUE(actual.exit_code != 0, "an unclosed '{' must not exit 0");
}

TEST_CASE(JsonRejectsUnmatchedClose, "json: a stray closing bracket is a hard error")
{
    auto actual = run_command(nshbox_path(), {"json"}, R"({"a":1}})");

    ASSERT_TRUE(actual.exit_code != 0, "an extra '}' with no matching '{' must not exit 0");
}

TEST_CASE(JsonTopLevelScalar, "json: a bare top-level scalar (no object/array) passes through")
{
    auto actual = run_command(nshbox_path(), {"json"}, "42");

    ASSERT_EQ(actual.stdout_data, "42\n", "json pretty-print of a bare top-level number");
    ASSERT_TRUE(actual.exit_code == 0, "a bare scalar is valid JSON per RFC 8259 and must exit 0");
}

// "--JSON"/"--Json" (see dispatch_command() in nshbox.c) is one shared
// routine reused by every --json-emitting command, not something
// reimplemented per command - so this one wiring check (using "find" as
// a representative example) stands in for all of them: it proves the
// dispatch layer's own captured-output-piped-through-json_pretty_print()
// mechanism works, which is the only part that isn't already covered by
// this file's direct tests of json_pretty_print() itself above, or by
// test_find.cpp's own coverage of "find --json" being correct compact
// JSON in the first place.
TEST_CASE(JsonFlagMatchesPipingThroughJsonCommand, "json: '--JSON' on a real command matches piping --json through nshbox json")
{
    TempDir dir;
    dir.write_file("a.txt", "x");
    dir.write_file("b.txt", "x");

    auto piped_json = run_command(nshbox_path(), {"find", dir.path(), "--json"});
    auto piped = run_command(nshbox_path(), {"json"}, piped_json.stdout_data);
    auto direct = run_command(nshbox_path(), {"find", dir.path(), "--JSON"});

    ASSERT_EQ(direct.stdout_data, piped.stdout_data, "find --JSON vs find --json | nshbox json");

    auto direct_alias = run_command(nshbox_path(), {"find", dir.path(), "--Json"});
    ASSERT_EQ(direct_alias.stdout_data, piped.stdout_data, "find --Json (alias) vs find --json | nshbox json");
}

TEST_CASE(JsonFlagDoesNotAffectPlainJson, "json: plain --json output is unaffected by the --JSON/--Json mechanism existing")
{
    TempDir dir;
    dir.write_file("a.txt", "x");

    auto actual = run_command(nshbox_path(), {"find", dir.path(), "--json"});

    // Compact: no newline anywhere in the middle of the output, just the
    // one at the very end that printf("...\n") already added.
    auto newline_count = std::count(actual.stdout_data.begin(), actual.stdout_data.end(), '\n');
    ASSERT_TRUE(newline_count <= 1, "plain --json must stay single-line/compact, not get pretty-printed");
}
