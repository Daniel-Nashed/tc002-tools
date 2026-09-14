#include "framework.hpp"

#include <cstdlib>
#include <iostream>

int main(int argc, char **argv)
{
    if (argc != 2) {
        std::cerr << "Usage: nshbox_tests <path-to-nshbox-binary>\n";
        return 2;
    }

    // nshbox has no locale awareness at all (plain strcmp for sort,
    // plain byte comparison throughout - confirmed, no setlocale()/
    // strcoll() anywhere in nshbox.c), so it always collates in C-locale
    // byte order. Forcing the same locale for the real reference tools
    // this harness diffs against (grep, sort, ...) keeps the comparison
    // apples-to-apples regardless of what locale the container image
    // happens to default to.
    ::setenv("LC_ALL", "C", 1);

    nshtest::set_nshbox_path(argv[1]);

    return nshtest::TestRegistry::instance().run_all() == 0 ? 0 : 1;
}
