// Tests the TOTP engine (totp_generate()/hotp_generate() in nshbox.c) against
// the official RFC 6238 Appendix B test vectors, exercised through the "nshbox
// totp" CLI - the only way to reach it from outside the binary (see
// requirements: "Tests must validate the TOTP engine independently from the
// HTTP server", which this does since HTTP does not exist yet).
//
// RFC 6238's test vectors use RAW ASCII byte secrets, not Base32 - "12345678
// 90123456789 0" repeated/extended to 20/32/64 bytes for SHA1/SHA256/SHA512
// respectively (RFC 6238 Appendix B: "The test token shared secret uses the
// ASCII string value '12345678901234567890'"). Since the CLI only accepts a
// Base32 --secret, these three constants are that exact same ASCII byte
// string Base32-encoded (RFC 4648, no padding) - computed once by hand with a
// from-scratch RFC 4648 encoder (mirroring nshbox's own decoder) and not
// re-derived here, so what is being tested is genuinely "does nshbox decode
// this Base32 back into the RFC's raw bytes and then compute the RFC's code",
// not a tautology against nshbox's own encoder.
#include "framework.hpp"
#include "run_command.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;

namespace {

// Base32 (RFC 4648, no padding) of "12345678901234567890" (20 ASCII bytes) -
// the RFC 6238 Appendix B SHA1 seed.
const std::string kSeedSha1 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

// Base32 of "12345678901234567890123456789012" (32 ASCII bytes) - the SHA256 seed.
const std::string kSeedSha256 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA";

// Base32 of "1234567890123456789012345678901234567890123456789012345678901234"
// (64 ASCII bytes) - the SHA512 seed.
const std::string kSeedSha512 =
    "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    "GEZDGNBVGY3TQOJQGEZDGNA";

struct Vector
{
    const char *time;
    const char *expected_code;   // 8 digits, RFC 6238 Appendix B
};

// RFC 6238 Appendix B, quoted verbatim (time step X = 30s, T0 = 0).
const Vector kSha1Vectors[] = {
    {"59",          "94287082"},
    {"1111111109",  "07081804"},
    {"1111111111",  "14050471"},
    {"1234567890",  "89005924"},
    {"2000000000",  "69279037"},
    {"20000000000", "65353130"},
};

const Vector kSha256Vectors[] = {
    {"59",          "46119246"},
    {"1111111109",  "68084774"},
    {"1111111111",  "67062674"},
    {"1234567890",  "91819424"},
    {"2000000000",  "90698825"},
    {"20000000000", "77737706"},
};

const Vector kSha512Vectors[] = {
    {"59",          "90693936"},
    {"1111111109",  "25091201"},
    {"1111111111",  "99943326"},
    {"1234567890",  "93441116"},
    {"2000000000",  "38618901"},
    {"20000000000", "47863826"},
};

void check_vectors(const std::string &secret, const std::string &algo, const Vector *vectors, size_t count)
{
    for (size_t i = 0; i < count; i++) {
        auto actual = run_command(nshbox_path(),
            {"totp", "--secret", secret, "--algorithm", algo, "--digits", "8", "--time", vectors[i].time});

        ASSERT_TRUE(actual.exit_code == 0,
            "totp --algorithm " + algo + " --time " + vectors[i].time + " must exit 0 (stderr: " + actual.stderr_data + ")");
        ASSERT_EQ(actual.stdout_data, std::string(vectors[i].expected_code) + "\n",
            "totp --algorithm " + algo + " --time " + vectors[i].time + " (RFC 6238 Appendix B)");
    }
}

} // namespace

TEST_CASE(TotpRfc6238Sha1Vectors, "totp: matches all six RFC 6238 SHA1 test vectors")
{
    check_vectors(kSeedSha1, "sha1", kSha1Vectors, 6);
}

TEST_CASE(TotpRfc6238Sha256Vectors, "totp: matches all six RFC 6238 SHA256 test vectors")
{
    check_vectors(kSeedSha256, "sha256", kSha256Vectors, 6);
}

TEST_CASE(TotpRfc6238Sha512Vectors, "totp: matches all six RFC 6238 SHA512 test vectors")
{
    check_vectors(kSeedSha512, "sha512", kSha512Vectors, 6);
}

TEST_CASE(TotpDefaultsMatchSha256SixDigits, "totp: default algorithm/digits/period is SHA256/6/30 (RFC vector truncated to 6)")
{
    // Default algorithm is SHA256, not the more common SHA1 - deliberate, see
    // nshbox/README.md's "totp" section (this is for a device-to-device
    // secret, not a phone authenticator app, so there is no reason to inherit
    // SHA1 as the default the way those apps do). 46119246 with the default 6
    // digits is the low 6 digits: 119246 (dynamic truncation mod 10^digits,
    // see nshbox.c's own hotp_generate() - mathematically the low 6 decimal
    // digits of the 8-digit value, since 10^6 divides 10^8 evenly).
    auto actual = run_command(nshbox_path(), {"totp", "--secret", kSeedSha256, "--time", "59"});

    ASSERT_TRUE(actual.exit_code == 0, "totp with only --secret/--time must exit 0");
    ASSERT_EQ(actual.stdout_data, "119246\n", "totp default algorithm+digits truncates the RFC's own SHA256 8-digit vector correctly");
}

TEST_CASE(TotpDefaultIsNotSha1, "totp: omitting --algorithm does not silently fall back to SHA1")
{
    // A regression guard specifically for the default itself: the same
    // secret and time, once with no --algorithm (uses the default) and once
    // with --algorithm sha1 given explicitly, must give different codes - if
    // a later change accidentally reverted the default to SHA1, this would
    // otherwise pass unnoticed (both TotpDefaultsMatchSha256SixDigits above
    // and this test would need to break together to catch that; this one
    // does not depend on which algorithm the default actually is, only that
    // it differs from an explicit sha1).
    auto default_algo = run_command(nshbox_path(), {"totp", "--secret", kSeedSha256, "--time", "59"});
    auto explicit_sha1 = run_command(nshbox_path(), {"totp", "--secret", kSeedSha256, "--algorithm", "sha1", "--time", "59"});

    ASSERT_TRUE(default_algo.exit_code == 0 && explicit_sha1.exit_code == 0, "both totp runs must exit 0");
    ASSERT_TRUE(default_algo.stdout_data != explicit_sha1.stdout_data,
        "the default algorithm's code must differ from an explicit --algorithm sha1 (default must not be sha1)");
}

TEST_CASE(TotpLeadingZeroPreserved, "totp: a code with a leading zero keeps it in the output")
{
    // 07081804 at t=1111111109 - the RFC vector that happens to start with 0,
    // the one case that would silently look "wrong but still 8 chars" if
    // printf used "%d" instead of "%0*u".
    auto actual = run_command(nshbox_path(),
        {"totp", "--secret", kSeedSha1, "--algorithm", "sha1", "--digits", "8", "--time", "1111111109"});

    ASSERT_TRUE(actual.exit_code == 0, "totp must exit 0");
    ASSERT_EQ(actual.stdout_data, "07081804\n", "leading zero must be preserved, and the string must be exactly 8 characters");
    ASSERT_TRUE(actual.stdout_data.size() == 9 /* 8 digits + \n */, "output must not be trimmed to 7 digits");
}

TEST_CASE(TotpInvalidBase32Rejected, "totp: an invalid Base32 secret is rejected, not silently truncated")
{
    auto actual = run_command(nshbox_path(), {"totp", "--secret", "not-valid-base32!!!"});

    ASSERT_TRUE(actual.exit_code != 0, "an invalid Base32 secret must fail");
    ASSERT_TRUE(actual.stdout_data.empty(), "a failed totp must print no code");
}

TEST_CASE(TotpInvalidAlgorithmRejected, "totp: an unknown --algorithm is rejected")
{
    auto actual = run_command(nshbox_path(), {"totp", "--secret", kSeedSha1, "--algorithm", "md5"});

    ASSERT_TRUE(actual.exit_code != 0, "an unsupported --algorithm must fail");
}

TEST_CASE(TotpInvalidPeriodRejected, "totp: a zero or negative --period is rejected")
{
    auto zero = run_command(nshbox_path(), {"totp", "--secret", kSeedSha1, "--period", "0"});
    auto negative = run_command(nshbox_path(), {"totp", "--secret", kSeedSha1, "--period", "-1"});

    ASSERT_TRUE(zero.exit_code != 0, "--period 0 must fail (division by zero must never reach the arithmetic)");
    ASSERT_TRUE(negative.exit_code != 0, "a negative --period must fail");
}

TEST_CASE(TotpInvalidDigitsRejected, "totp: an out-of-range --digits is rejected")
{
    auto too_few = run_command(nshbox_path(), {"totp", "--secret", kSeedSha1, "--digits", "5"});
    auto too_many = run_command(nshbox_path(), {"totp", "--secret", kSeedSha1, "--digits", "9"});

    ASSERT_TRUE(too_few.exit_code != 0, "--digits 5 must fail (below the supported 6-8 range)");
    ASSERT_TRUE(too_many.exit_code != 0, "--digits 9 must fail (above the supported 6-8 range)");
}

TEST_CASE(TotpMissingSecretRejected, "totp: no --secret at all is rejected with a usage message, not a crash")
{
    auto actual = run_command(nshbox_path(), {"totp"});

    ASSERT_TRUE(actual.exit_code != 0, "totp with no arguments must fail");
}

TEST_CASE(TotpErrorNeverEchoesSecret, "totp: an error for an invalid secret never prints the secret itself")
{
    const std::string bogus_secret = "THIS-IS-NOT-VALID-BASE32-AT-ALL";
    auto actual = run_command(nshbox_path(), {"totp", "--secret", bogus_secret});

    ASSERT_TRUE(actual.exit_code != 0, "an invalid secret must fail");
    ASSERT_TRUE(actual.stderr_data.find(bogus_secret) == std::string::npos,
        "the invalid secret must never appear in the error message");
}
