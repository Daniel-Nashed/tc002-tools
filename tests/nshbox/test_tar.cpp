// Round-trips nshbox's tar against real GNU tar - both directions
// (nshbox creates, real tar extracts; real tar creates, nshbox extracts)
// plus gzip interop (-z, see nshbox/src/nshbox.c's fork/pipe/execlp
// wrapper around the gzip binary). Compares extracted file CONTENT, not
// raw archive bytes - two tar implementations can produce a
// byte-different but equally valid ustar archive (header field padding,
// block alignment details), so content survival through a real
// implementation is the actual interop question, not byte-for-byte
// archive equality.
#include "framework.hpp"
#include "run_command.hpp"
#include "temp_fixture.hpp"
#include "text_utils.hpp"

using nshtest::run_command;
using nshtest::nshbox_path;
using nshtest::TempDir;
using nshtest::read_file;
using nshtest::sorted_lines;
using nshtest::join_lines;

TEST_CASE(TarNshboxCreatesRealExtracts, "tar: nshbox creates, real tar extracts")
{
    TempDir src;
    TempDir dest;

    src.write_file("one.txt", "first file\n");
    src.write_file("two.txt", "second file, a bit longer\n");

    std::string archive = src.child("out.tar");

    auto create = run_command(nshbox_path(), {"tar", "-cf", archive, "-C", src.path(), "one.txt", "two.txt"});
    ASSERT_TRUE(create.exit_code == 0, "nshbox tar -cf succeeded");

    auto extract = run_command("tar", {"-xf", archive, "-C", dest.path()});
    ASSERT_TRUE(extract.exit_code == 0, "real tar -xf succeeded on nshbox's archive");

    ASSERT_EQ(read_file(dest.child("one.txt")), "first file\n", "one.txt content survived nshbox->real round trip");
    ASSERT_EQ(read_file(dest.child("two.txt")), "second file, a bit longer\n",
              "two.txt content survived nshbox->real round trip");
}

TEST_CASE(TarRealCreatesNshboxExtracts, "tar: real tar creates, nshbox extracts")
{
    TempDir src;
    TempDir dest;

    src.write_file("alpha.txt", "alpha content\n");
    src.write_file("beta.txt", "beta content, different length\n");

    std::string archive = src.child("out.tar");

    auto create = run_command("tar", {"-cf", archive, "-C", src.path(), "alpha.txt", "beta.txt"});
    ASSERT_TRUE(create.exit_code == 0, "real tar -cf succeeded");

    auto extract = run_command(nshbox_path(), {"tar", "-xf", archive, "-C", dest.path()});
    ASSERT_TRUE(extract.exit_code == 0, "nshbox tar -xf succeeded on real tar's archive");

    ASSERT_EQ(read_file(dest.child("alpha.txt")), "alpha content\n", "alpha.txt content survived real->nshbox round trip");
    ASSERT_EQ(read_file(dest.child("beta.txt")), "beta content, different length\n",
              "beta.txt content survived real->nshbox round trip");
}

TEST_CASE(TarListMembersMatch, "tar: -t member listing matches between both tools")
{
    TempDir src;

    src.write_file("x.txt", "x");
    src.write_file("y.txt", "y");

    std::string archive = src.child("out.tar");
    run_command("tar", {"-cf", archive, "-C", src.path(), "x.txt", "y.txt"});

    auto real_list = run_command("tar", {"-tf", archive});
    auto nshbox_list = run_command(nshbox_path(), {"tar", "-tf", archive});

    ASSERT_EQ(join_lines(sorted_lines(nshbox_list.stdout_data)),
              join_lines(sorted_lines(real_list.stdout_data)),
              "tar -t member listing");
}

TEST_CASE(TarGzipNshboxCreatesRealExtracts, "tar: nshbox creates .tar.gz, real tar extracts")
{
    TempDir src;
    TempDir dest;

    src.write_file("data.txt", "compressed round trip content\n");

    std::string archive = src.child("out.tar.gz");

    // -z explicitly, not relying on the .tar.gz name auto-detection, so
    // this test is exercising the same flag real tar's own -z takes.
    auto create = run_command(nshbox_path(), {"tar", "-czf", archive, "-C", src.path(), "data.txt"});
    ASSERT_TRUE(create.exit_code == 0, "nshbox tar -czf succeeded");

    auto extract = run_command("tar", {"-xzf", archive, "-C", dest.path()});
    ASSERT_TRUE(extract.exit_code == 0, "real tar -xzf succeeded on nshbox's gzip archive");

    ASSERT_EQ(read_file(dest.child("data.txt")), "compressed round trip content\n",
              "content survived nshbox(gzip)->real round trip");
}

TEST_CASE(TarGzipRealCreatesNshboxExtracts, "tar: real tar creates .tar.gz, nshbox extracts")
{
    TempDir src;
    TempDir dest;

    src.write_file("data.txt", "the other direction this time\n");

    std::string archive = src.child("out.tar.gz");

    auto create = run_command("tar", {"-czf", archive, "-C", src.path(), "data.txt"});
    ASSERT_TRUE(create.exit_code == 0, "real tar -czf succeeded");

    auto extract = run_command(nshbox_path(), {"tar", "-xzf", archive, "-C", dest.path()});
    ASSERT_TRUE(extract.exit_code == 0, "nshbox tar -xzf succeeded on real tar's gzip archive");

    ASSERT_EQ(read_file(dest.child("data.txt")), "the other direction this time\n",
              "content survived real(gzip)->nshbox round trip");
}

TEST_CASE(TarExtractSingleNamedMember, "tar: extracting a named member skips the rest")
{
    TempDir src;
    TempDir dest;

    src.write_file("keep.txt", "keep this one\n");
    src.write_file("skip.txt", "not this one\n");

    std::string archive = src.child("out.tar");
    run_command("tar", {"-cf", archive, "-C", src.path(), "keep.txt", "skip.txt"});

    auto extract = run_command(nshbox_path(), {"tar", "-xf", archive, "-C", dest.path(), "keep.txt"});
    ASSERT_TRUE(extract.exit_code == 0, "nshbox tar -xf <archive> keep.txt succeeded");

    ASSERT_EQ(read_file(dest.child("keep.txt")), "keep this one\n", "named member was extracted");

    auto listing = run_command("find", {dest.path(), "-name", "skip.txt"});
    ASSERT_EQ(listing.stdout_data, std::string(""), "skip.txt was not extracted");
}
