// Hand-rolled test framework for the nshbox functional test suite - no
// external dependency (GoogleTest/Catch2/doctest), by deliberate choice:
// this project avoids adding a dependency it does not need, and a test
// suite comparing nshbox's own output against reference tools does not
// need fixtures, mocking, or parameterized tests, just "run this, assert
// on the result." See tests/nshbox/README.md.
#pragma once

#include <string>
#include <vector>
#include <stdexcept>

namespace nshtest {

// Thrown by ASSERT_* on failure; caught by TestRegistry::run_all() so one
// failing assertion fails only its own test, not the whole run.
class TestFailure : public std::runtime_error
{
public:
    explicit TestFailure(const std::string &message) : std::runtime_error(message) {}
};

class TestCase
{
public:
    explicit TestCase(std::string name);
    virtual ~TestCase() = default;

    virtual void run() = 0;

    const std::string &name() const { return name_; }

private:
    std::string name_;
};

class TestRegistry
{
public:
    static TestRegistry &instance();

    void add(TestCase *test);

    // Runs every registered test, printing PASS/FAIL per test and a
    // final summary to stdout. Returns the number of failures (0 on a
    // clean run) - main() turns that into the process exit code.
    int run_all();

private:
    std::vector<TestCase *> tests_;
};

void assert_eq(const std::string &actual, const std::string &expected,
               const std::string &context, const char *file, int line);
void assert_true(bool condition, const std::string &context, const char *file, int line);

// Set once by main() from argv[1] - the nshbox binary under test. Every
// test file reads nshbox_path() rather than constructing its own guess
// at where dist/<platform>/nshbox lives.
void set_nshbox_path(const std::string &path);
const std::string &nshbox_path();

} // namespace nshtest

// Defines a self-registering TestCase subclass:
//
//   TEST_CASE(GrepBasicMatch, "grep: basic literal match")
//   {
//       ... body runs as TestCase::run() ...
//   }
//
// ClassName must be unique across the whole suite (it is a real C++
// class name) - the convention here is CommandAction, e.g.
// GrepCaseInsensitive, WcLineCount; TestName is the human-readable label
// printed at run time and does not need to be unique. The static
// instance's constructor registers itself with TestRegistry at
// static-init time, before main() runs - the same self-registration idea
// GoogleTest's own TEST() macro uses, hand-rolled here instead of
// pulling in that dependency.
#define TEST_CASE(ClassName, TestName)                                                     \
    class ClassName : public ::nshtest::TestCase                                            \
    {                                                                                        \
    public:                                                                                  \
        ClassName() : ::nshtest::TestCase(TestName) { ::nshtest::TestRegistry::instance().add(this); } \
        void run() override;                                                                 \
    };                                                                                        \
    static ClassName ClassName##_instance;                                                   \
    void ClassName::run()

#define ASSERT_EQ(actual, expected, context) \
    ::nshtest::assert_eq((actual), (expected), (context), __FILE__, __LINE__)

#define ASSERT_TRUE(condition, context) \
    ::nshtest::assert_true((condition), (context), __FILE__, __LINE__)
