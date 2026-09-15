// Exercises nshbox's own jwt command - see cmd_jwt()/jwt_decode_segment()
// in nshbox/src/nshbox.c. There is no widely-available reference CLI tool
// to diff a JWT decode against the way other commands here diff against
// real coreutils, so these tests instead check against a well-known,
// publicly documented example token (the default sample shown on jwt.io)
// and against tokens this test builds itself with nshbox's own
// "base64 -u", which doubles as an end-to-end check that "jwt" and
// "base64 -u" agree with each other.
#include "framework.hpp"
#include "run_command.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;

namespace {

std::string base64url_encode(const std::string &input)
{
    return run_command(nshbox_path(), {"base64", "-u", "-w", "0"}, input).stdout_data;
}

} // namespace

namespace {

// https://jwt.io's own default example token - header {"alg":"HS256",
// "typ":"JWT"}, payload {"sub":"1234567890","name":"John
// Doe","iat":1516239022} - publicly documented, stable, and requires no
// secret to decode (decoding never touches the signature).
const std::string kSampleToken =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ."
    "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
const std::string kSampleHeader = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}\n";
const std::string kSamplePayload = "{\"sub\":\"1234567890\",\"name\":\"John Doe\",\"iat\":1516239022}\n";

} // namespace

TEST_CASE(JwtDefaultShowsPayloadOnly, "jwt: default (no flag) prints the payload only")
{
    auto actual = run_command(nshbox_path(), {"jwt", kSampleToken});

    ASSERT_EQ(actual.stdout_data, kSamplePayload, "jwt with no flag");
    ASSERT_TRUE(actual.exit_code == 0, "jwt decode of a well-formed token must exit 0");
}

TEST_CASE(JwtHeaderFlagShowsHeaderOnly, "jwt: --header prints the header only")
{
    auto actual = run_command(nshbox_path(), {"jwt", "--header", kSampleToken});

    ASSERT_EQ(actual.stdout_data, kSampleHeader, "jwt --header");
}

TEST_CASE(JwtAllFlagShowsBoth, "jwt: --all prints header then payload")
{
    auto actual = run_command(nshbox_path(), {"jwt", "--all", kSampleToken});

    ASSERT_EQ(actual.stdout_data, kSampleHeader + kSamplePayload, "jwt --all");
}

TEST_CASE(JwtDecodesViaStdin, "jwt: reads the token from stdin when no argument is given")
{
    auto via_arg = run_command(nshbox_path(), {"jwt", kSampleToken});
    auto via_stdin = run_command(nshbox_path(), {"jwt"}, kSampleToken + "\n");

    ASSERT_EQ(via_stdin.stdout_data, via_arg.stdout_data, "jwt via stdin vs jwt via argument");
}

TEST_CASE(JwtRoundTripsSelfBuiltToken, "jwt: decodes (--all) a token this test builds itself with base64 -u")
{
    std::string header_json = R"({"alg":"none","typ":"JWT"})";
    std::string payload_json = R"({"user":"tc002-tools","admin":true,"n":42})";

    std::string token = base64url_encode(header_json) + "." +
                         base64url_encode(payload_json) + "." +
                         "signature-not-checked";

    auto actual = run_command(nshbox_path(), {"jwt", "--all", token});
    std::string expected = header_json + "\n" + payload_json + "\n";

    ASSERT_EQ(actual.stdout_data, expected, "jwt --all decode of a self-built token");
}

TEST_CASE(JwtRejectsMalformedInput, "jwt: rejects input with fewer than two '.' separators")
{
    auto no_dots = run_command(nshbox_path(), {"jwt", "notajwt"});
    ASSERT_TRUE(no_dots.exit_code != 0, "jwt must reject a token with no '.' at all");

    auto one_dot = run_command(nshbox_path(), {"jwt", "header.payload"});
    ASSERT_TRUE(one_dot.exit_code != 0, "jwt must reject a token with only one '.'");
}

TEST_CASE(JwtRejectsInvalidBase64Segment, "jwt: rejects a token whose segment isn't valid base64url")
{
    auto actual = run_command(nshbox_path(), {"jwt", "not valid!.also not valid!.sig"});

    ASSERT_TRUE(actual.exit_code != 0, "jwt must fail, not print garbage, for an undecodable segment");
}
