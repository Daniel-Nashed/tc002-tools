// Compares nshbox's tree against real tree(1) - a raw diff, not field
// extraction, since nshbox's tree was deliberately modeled to match real
// tree's own box-drawing connectors and "N directories, M files" summary
// convention (see nshbox/src/nshbox.c's tree_walk()/cmd_tree()). Fixtures
// here never include dotfiles - real tree hides them by default and
// nshbox's tree never does (a documented, deliberate difference - see
// nshbox/README.md's "tree" section), so a raw diff would otherwise
// fail on that difference alone, not a real bug.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"

#include <vector>

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;

namespace {

// Real tree falls back to ASCII line-drawing ("|--", "`--") whenever its
// output is not a real terminal (confirmed directly, 2026-09-14 - every
// invocation through this harness's run_command() is a pipe, never a
// tty) - --charset=utf-8 forces the same Unicode box-drawing characters
// nshbox's own tree always uses, regardless of that detection.
//
// Real tree also pads its indentation with U+00A0 (NO-BREAK SPACE, UTF-8
// bytes 0xC2 0xA0) instead of a plain ASCII space - confirmed directly,
// 2026-09-14, by a byte-level diff after the two outputs looked visually
// identical in every terminal check (NBSP renders the same as a normal
// space almost everywhere). Not worth chasing in nshbox's own tree: this
// looks like it exists for tree's own HTML output mode, and deliberately
// emitting non-breaking spaces into plain-text terminal output would be
// a strictly worse choice for a tool with no HTML mode of its own to
// justify it. Normalized away here instead, on the real-tree side only.
std::string strip_nbsp(const std::string &text)
{
    std::string out;

    for (size_t i = 0; i < text.size(); i++) {
        if (i + 1 < text.size() &&
                static_cast<unsigned char>(text[i]) == 0xC2 &&
                static_cast<unsigned char>(text[i + 1]) == 0xA0) {
            out += ' ';
            i++;
        } else {
            out += text[i];
        }
    }

    return out;
}

nshtest::CommandResult run_real_tree(const std::vector<std::string> &args)
{
    std::vector<std::string> full_args = {"--charset=utf-8"};
    full_args.insert(full_args.end(), args.begin(), args.end());

    nshtest::CommandResult result = run_command("tree", full_args);
    result.stdout_data = strip_nbsp(result.stdout_data);

    return result;
}

} // namespace

TEST_CASE(TreeEmptyDirectory, "tree: an empty directory")
{
    TempDir dir;

    auto expected = run_real_tree({dir.path()});
    auto actual = run_command(nshbox_path(), {"tree", dir.path()});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "tree on an empty directory");
}

TEST_CASE(TreeSingleFile, "tree: a directory with just one file")
{
    TempDir dir;
    dir.write_file("f.txt", "x");

    auto expected = run_real_tree({dir.path()});
    auto actual = run_command(nshbox_path(), {"tree", dir.path()});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "tree with a single file");
}

TEST_CASE(TreeNestedStructure, "tree: a multi-level tree with a symlink")
{
    TempDir dir;

    run_command("mkdir", {"-p", dir.child("a/b")});
    dir.write_file("root.txt", "x");
    dir.write_file("a/one.txt", "x");
    dir.write_file("a/b/deep.txt", "x");

    std::string target = dir.child("root.txt");
    std::string link = dir.child("a/link.txt");
    run_command("ln", {"-s", target, link});

    auto expected = run_real_tree({dir.path()});
    auto actual = run_command(nshbox_path(), {"tree", dir.path()});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "tree on a nested tree with a symlink");
}

TEST_CASE(TreeMaxLevelOne, "tree: -L 1 stops at immediate children")
{
    TempDir dir;

    run_command("mkdir", {"-p", dir.child("a/b")});
    dir.write_file("root.txt", "x");

    auto expected = run_real_tree({"-L", "1", dir.path()});
    auto actual = run_command(nshbox_path(), {"tree", "-L", "1", dir.path()});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "tree -L 1");
}

TEST_CASE(TreeMaxLevelTwo, "tree: -L 2 shows two levels deep")
{
    TempDir dir;

    run_command("mkdir", {"-p", dir.child("a/b/c")});
    dir.write_file("a/one.txt", "x");
    dir.write_file("a/b/two.txt", "x");

    auto expected = run_real_tree({"-L", "2", dir.path()});
    auto actual = run_command(nshbox_path(), {"tree", "-L", "2", dir.path()});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data, "tree -L 2");
}

TEST_CASE(TreeEmptySubdirectory, "tree: root containing only one empty subdirectory")
{
    TempDir dir;

    run_command("mkdir", {dir.child("sub")});

    auto expected = run_real_tree({dir.path()});
    auto actual = run_command(nshbox_path(), {"tree", dir.path()});

    ASSERT_EQ(actual.stdout_data, expected.stdout_data,
              "tree with one empty subdirectory - the root-counting edge case this test exists for");
}
