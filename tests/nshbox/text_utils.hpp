// Small text helpers shared by tests whose reference tool does not
// guarantee the same directory-enumeration order nshbox uses (both walk
// the same real filesystem via readdir(), which is stable for an
// unmodified directory in practice, but comparing as an unordered set of
// lines removes that assumption entirely rather than relying on it).
#pragma once

#include <string>
#include <vector>

namespace nshtest {

// Splits text on '\n', dropping a single trailing empty element from a
// final newline (so "a\nb\n" and "a\nb" both split to {"a", "b"}).
std::vector<std::string> split_lines(const std::string &text);

// split_lines() + std::sort - for comparing two tools' multi-line output
// as a set, independent of enumeration order.
std::vector<std::string> sorted_lines(const std::string &text);

// Joins with '\n' (no trailing newline) - pairs with sorted_lines() so a
// test can still hand ASSERT_EQ two plain strings and get a readable
// expected/actual diff on failure, rather than comparing vectors directly.
std::string join_lines(const std::vector<std::string> &lines);

} // namespace nshtest
