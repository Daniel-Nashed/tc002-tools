#include "framework.hpp"

#include <iostream>
#include <sstream>

namespace nshtest {

namespace {
std::string g_nshbox_path;
} // namespace

void set_nshbox_path(const std::string &path)
{
    g_nshbox_path = path;
}

const std::string &nshbox_path()
{
    return g_nshbox_path;
}

TestCase::TestCase(std::string name) : name_(std::move(name)) {}

TestRegistry &TestRegistry::instance()
{
    static TestRegistry registry;
    return registry;
}

void TestRegistry::add(TestCase *test)
{
    tests_.push_back(test);
}

int TestRegistry::run_all()
{
    int failures = 0;

    std::cout << "running " << tests_.size() << " test(s)\n\n";

    for (TestCase *test : tests_) {
        try {
            test->run();
            std::cout << "[  OK  ] " << test->name() << '\n';
        } catch (const TestFailure &failure) {
            std::cout << "[ FAIL ] " << test->name() << ":\n  " << failure.what() << '\n';
            failures++;
        } catch (const std::exception &e) {
            std::cout << "[ FAIL ] " << test->name() << ": unexpected exception: " << e.what() << '\n';
            failures++;
        }
    }

    // Same banner shape as build/common.sh's own header()/delim() (80
    // dashes, blank line above and below) - the rest of this project's
    // build/install output already uses that for "this phase is done"
    // messages, so the harness's own final summary matches rather than
    // introducing a different visual style just for this one line.
    std::string delim(80, '-');
    std::string summary = (failures == 0)
        ? "PASS: all " + std::to_string(tests_.size()) + " test(s) passed"
        : "FAIL: " + std::to_string(failures) + " of " + std::to_string(tests_.size()) + " test(s) failed";

    std::cout << '\n' << delim << '\n' << summary << '\n' << delim << "\n\n";

    return failures;
}

void assert_eq(const std::string &actual, const std::string &expected,
               const std::string &context, const char *file, int line)
{
    if (actual == expected)
        return;

    std::ostringstream message;
    message << context << " (" << file << ':' << line << ")\n"
            << "    expected: " << expected << '\n'
            << "    actual:   " << actual;

    throw TestFailure(message.str());
}

void assert_true(bool condition, const std::string &context, const char *file, int line)
{
    if (condition)
        return;

    std::ostringstream message;
    message << context << " (" << file << ':' << line << ")";

    throw TestFailure(message.str());
}

} // namespace nshtest
