// Compares nshbox's own base64 against real GNU base64(1)/basenc(1) - see
// base64_encode_stream()/base64_decode_stream() in nshbox/src/nshbox.c, a
// from-scratch RFC 4648 implementation (no OpenSSL involved - base64 is
// not cryptography). Standard-alphabet cases diff against real "base64";
// URL-safe ("-u") cases diff against real "basenc --base64url", since GNU
// coreutils' own "base64" has no URL-safe mode to compare against.
#include "framework.hpp"
#include "run_command.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;

namespace {

// Real base64 defaults to wrapping at 76 columns and has no way to
// disable it except "-w0" (or "-w 0") - matched exactly by nshbox's own
// default and "-w" flag, so every encode comparison below uses "-w0" to
// keep expected output on one predictable line.
std::string long_text()
{
    // Deliberately over 57 raw bytes (which encodes to over 76 base64
    // chars), so a comparison run WITHOUT -w0 would catch a wrapping bug
    // - used once below specifically for that case.
    return "hello world, this is a test string longer than fifty-seven bytes, on purpose!";
}

} // namespace

TEST_CASE(Base64EncodeMatchesReal, "base64: encode matches real base64 (short input)")
{
    std::string input = "The quick brown fox jumps over the lazy dog";

    auto expected = run_command("base64", {"-w0"}, input);
    auto actual = run_command(nshbox_path(), {"base64", "-w", "0"}, input);

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "base64 encode vs real base64 -w0");
}

TEST_CASE(Base64EncodeWrapsLikeReal, "base64: default line-wrapping matches real base64 (no -w)")
{
    std::string input = long_text();

    auto expected = run_command("base64", {}, input);
    auto actual = run_command(nshbox_path(), {"base64"}, input);

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "base64 default wrap vs real base64 default wrap");
}

TEST_CASE(Base64EncodeEmptyInput, "base64: encoding empty input matches real base64")
{
    auto expected = run_command("base64", {"-w0"}, "");
    auto actual = run_command(nshbox_path(), {"base64", "-w", "0"}, "");

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "base64 encode of empty input");
}

TEST_CASE(Base64EncodeBinaryData, "base64: encode matches real base64 on raw binary bytes")
{
    std::string input;
    for (int i = 0; i < 256; i++)
        input.push_back(static_cast<char>(i));

    auto expected = run_command("base64", {"-w0"}, input);
    auto actual = run_command(nshbox_path(), {"base64", "-w", "0"}, input);

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "base64 encode of all 256 byte values");
}

TEST_CASE(Base64DecodeRoundTrip, "base64: decode reverses nshbox's own encode")
{
    std::string input = "round trip this exact string through encode then decode";

    auto encoded = run_command(nshbox_path(), {"base64"}, input);
    auto decoded = run_command(nshbox_path(), {"base64", "-d"}, encoded.stdout_data);

    ASSERT_EQ(decoded.stdout_data, input, "base64 decode(encode(x)) == x");
}

TEST_CASE(Base64DecodeMatchesReal, "base64: decode matches real base64 -d")
{
    std::string input = "some arbitrary text to decode after encoding it first";
    auto encoded = run_command("base64", {"-w0"}, input);

    auto expected = run_command("base64", {"-d"}, encoded.stdout_data);
    auto actual = run_command(nshbox_path(), {"base64", "-d"}, encoded.stdout_data);

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "base64 -d vs real base64 -d on the same input");
}

TEST_CASE(Base64UrlSafeEncodeMatchesBasenc, "base64: -u encode matches real basenc --base64url")
{
    // Bytes chosen so the standard alphabet's "+"/"/" characters would
    // definitely appear if this were encoded without -u - the whole
    // point of this test is confirming they come out as "-"/"_" instead.
    std::string input;
    input.push_back(static_cast<char>(0xfb));
    input.push_back(static_cast<char>(0xff));
    input.push_back(static_cast<char>(0xfe));
    input += "subject?a=1&b=2";

    auto expected = run_command("basenc", {"--base64url", "-w0"}, input);
    auto actual = run_command(nshbox_path(), {"base64", "-u", "-w", "0"}, input);

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "base64 -u vs real basenc --base64url");
}

TEST_CASE(Base64UrlSafeRoundTrip, "base64: -u decode reverses -u encode")
{
    std::string input;
    for (int i = 0; i < 256; i++)
        input.push_back(static_cast<char>(i));

    auto encoded = run_command(nshbox_path(), {"base64", "-u", "-w", "0"}, input);
    auto decoded = run_command(nshbox_path(), {"base64", "-d", "-u"}, encoded.stdout_data);

    ASSERT_EQ(decoded.stdout_data, input, "base64 -u decode(encode(x)) == x for all 256 byte values");
}

TEST_CASE(Base64DecodeToleratesMissingPadding, "base64: decode accepts a final group with no '=' padding")
{
    // "aGVsbG8" (no trailing "=") decodes to "hello" under the lenient,
    // JWT-style rule documented in nshbox/README.md - real GNU base64
    // rejects this outright, so there is no reference tool to diff
    // against here; the expected value is just the known plaintext.
    auto actual = run_command(nshbox_path(), {"base64", "-d"}, "aGVsbG8");

    ASSERT_EQ(actual.stdout_data, "hello", "base64 -d of unpadded 'aGVsbG8'");
}

TEST_CASE(Base64DecodeRejectsInvalidInput, "base64: decode rejects a non-alphabet character")
{
    auto actual = run_command(nshbox_path(), {"base64", "-d"}, "not valid base64 !!!");

    ASSERT_TRUE(actual.exit_code != 0, "base64 -d must fail on invalid input, not silently produce garbage");
}
