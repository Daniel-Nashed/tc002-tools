// RAII temp-directory fixture - the payoff of using C++ classes for
// tests: a TempDir is always cleaned up when it goes out of scope,
// including when an ASSERT_* throws partway through a test, so a failing
// test never leaves litter behind for the next one to trip over.
#pragma once

#include <string>

namespace nshtest {

class TempDir
{
public:
    TempDir();
    ~TempDir();

    TempDir(const TempDir &) = delete;
    TempDir &operator=(const TempDir &) = delete;

    // Move-only, not just non-copyable: deleting the copy constructor
    // suppresses the compiler's implicit move constructor too, and a
    // factory-style helper returning a freshly-populated TempDir by
    // value (see e.g. test_find.cpp's make_sample_tree()) needs one -
    // named-return-value optimization is an optimization, not a C++17
    // guarantee, so a move constructor must actually exist as the
    // fallback. Transfers ownership of the directory (clears the
    // moved-from path_ so its destructor becomes a no-op) rather than
    // deep-copying, matching every other move-only RAII handle.
    TempDir(TempDir &&other) noexcept;
    TempDir &operator=(TempDir &&other) noexcept;

    const std::string &path() const { return path_; }

    // path() + "/" + name, for building a child file/directory path
    // without repeating the separator logic in every test.
    std::string child(const std::string &name) const;

    // Creates child(name) with the given content (truncating if it
    // already exists) and returns its full path, for convenience
    // chaining straight into a test's own command invocation.
    std::string write_file(const std::string &name, const std::string &content) const;

private:
    std::string path_;
};

// Reads a whole file's content into a string - the read-side counterpart
// to TempDir::write_file(), used to verify a file's content survived a
// round trip (e.g. through nshbox's own tar) unchanged. Throws if the
// file cannot be opened.
std::string read_file(const std::string &path);

} // namespace nshtest
