// Compares nshbox's own dirname against real GNU coreutils dirname(1) -
// see nshbox/src/nshbox.c's dirname_one(), a self-contained
// implementation deliberately NOT using libgen.h's dirname(3) (which is
// allowed to mutate its input and varies by libc) - this is exactly the
// kind of "does it actually match the real tool" question this harness
// exists to answer, run every time nshbox changes rather than by hand
// once at authorship time.
#include "framework.hpp"
#include "run_command.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;

namespace {

// Runs both "nshbox dirname <path>" and real "dirname <path>", asserting
// they agree - the actual comparison every test case below reduces to.
void assert_dirname_matches(const std::string &input)
{
    auto expected = run_command("dirname", {input});
    auto actual = run_command(nshbox_path(), {"dirname", input});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data,
              "nshbox dirname vs real dirname for input '" + input + "'");
}

} // namespace

TEST_CASE(DirnameSimplePath, "dirname: simple multi-component path")
{
    assert_dirname_matches("/a/b/c");
}

TEST_CASE(DirnameTrailingSlash, "dirname: trailing slash is stripped")
{
    assert_dirname_matches("/a/b/c/");
}

TEST_CASE(DirnameNoSlash, "dirname: no slash at all yields '.'")
{
    assert_dirname_matches("file.txt");
}

TEST_CASE(DirnameRootOnly, "dirname: root path stays '/'")
{
    assert_dirname_matches("/");
}

TEST_CASE(DirnameSingleComponent, "dirname: single leading-slash component")
{
    assert_dirname_matches("/etc");
}

TEST_CASE(DirnameMultipleTrailingSlashes, "dirname: multiple trailing slashes")
{
    assert_dirname_matches("/a/b///");
}
