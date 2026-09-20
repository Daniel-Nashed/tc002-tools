// Reverse (IP -> name) lookups in dig/nslookup - see dns_reverse_name() in
// nshbox/src/nshbox.c. Whether a PTR record exists depends on whatever
// resolver the container has, so these tests do not assert on the answer.
// They assert on the *name that was queried*: both a failed and a
// successful lookup print it (stderr "dig: <name>: ..." / stdout answer
// line), so it shows up either way - which is enough to pin the part that
// is easy to get wrong, the octet/nibble order. The documentation-only
// addresses used (192.0.2.0/24, 2001:db8::/32) will not have a real PTR
// record.
//
// Each of the three lookup tests makes one real DNS query, so a container
// with no working resolver makes them slow (resolver timeout), not failed.
#include "framework.hpp"
#include "run_command.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;

namespace {

std::string repeat(const std::string &s, int times)
{
    std::string out;

    for (int i = 0; i < times; i++)
        out += s;

    return out;
}

// stdout and stderr together - which stream carries the name depends on
// whether the lookup succeeded.
std::string all_output(const nshtest::CommandResult &r)
{
    return r.stdout_data + r.stderr_data;
}

const std::string kIp6ReverseName =
    "1.0." + repeat("0.0.", 11) + "8.b.d.0.1.0.0.2.ip6.arpa";

} // namespace

TEST_CASE(DigReverseIpv4Name, "dig -x: an IPv4 address is looked up as d.c.b.a.in-addr.arpa")
{
    auto out = run_command(nshbox_path(), {"dig", "-x", "192.0.2.10"});

    ASSERT_TRUE(all_output(out).find("10.2.0.192.in-addr.arpa") != std::string::npos,
                "octets are reversed in the queried name");
}

TEST_CASE(DigReverseIpv6Name, "dig -x: an IPv6 address is looked up as reversed nibbles under ip6.arpa")
{
    auto out = run_command(nshbox_path(), {"dig", "-x", "2001:db8::1"});

    ASSERT_TRUE(all_output(out).find(kIp6ReverseName) != std::string::npos,
                "32 nibbles, least significant first, under ip6.arpa");
}

TEST_CASE(NslookupIpArgumentIsReversed, "nslookup: an IP address argument is looked up in reverse, no -x needed")
{
    auto out = run_command(nshbox_path(), {"nslookup", "192.0.2.10"});

    ASSERT_TRUE(all_output(out).find("10.2.0.192.in-addr.arpa") != std::string::npos,
                "nslookup reverses an IP argument on its own");
}

TEST_CASE(DigReverseRejectsNonIp, "dig -x: something that is not an IP address is a usage error, no query made")
{
    auto out = run_command(nshbox_path(), {"dig", "-x", "example.com"});

    ASSERT_TRUE(out.exit_code == 2, "usage error exits 2");
    ASSERT_TRUE(out.stderr_data.find("not an IPv4 or IPv6 address") != std::string::npos,
                "message says why");
}

TEST_CASE(DigReverseRejectsRecordType, "dig -x: combining -x with a record type is a usage error")
{
    auto out = run_command(nshbox_path(), {"dig", "-x", "192.0.2.10", "MX"});

    ASSERT_TRUE(out.exit_code == 2, "usage error exits 2");
}
