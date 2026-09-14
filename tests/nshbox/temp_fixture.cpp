#include "temp_fixture.hpp"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <utility>
#include <vector>

#include <ftw.h>
#include <sys/stat.h>

namespace nshtest {

namespace {

int remove_entry(const char *path, const struct stat *, int, struct FTW *)
{
    return ::remove(path);
}

// FTW_DEPTH: children removed before their parent directory, so rmdir()
// (which remove() calls for a directory entry) never runs on a
// non-empty one. FTW_PHYS: never follow a symlink while cleaning up -
// a fixture is never expected to contain one pointing outside itself,
// and this makes sure cleanup can't wander there even if a test bug
// created one.
void remove_recursive(const std::string &path)
{
    ::nftw(path.c_str(), remove_entry, 16, FTW_DEPTH | FTW_PHYS);
}

} // namespace

TempDir::TempDir()
{
    std::string tmpl = "/tmp/nshbox_test_XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');

    if (::mkdtemp(buf.data()) == nullptr)
        throw std::runtime_error(std::string("mkdtemp: ") + std::strerror(errno));

    path_ = buf.data();
}

TempDir::~TempDir()
{
    if (!path_.empty())
        remove_recursive(path_);
}

TempDir::TempDir(TempDir &&other) noexcept : path_(std::move(other.path_))
{
    other.path_.clear();
}

TempDir &TempDir::operator=(TempDir &&other) noexcept
{
    if (this != &other) {
        if (!path_.empty())
            remove_recursive(path_);

        path_ = std::move(other.path_);
        other.path_.clear();
    }

    return *this;
}

std::string TempDir::child(const std::string &name) const
{
    return path_ + "/" + name;
}

std::string TempDir::write_file(const std::string &name, const std::string &content) const
{
    std::string full_path = child(name);
    std::ofstream out(full_path, std::ios::binary | std::ios::trunc);

    if (!out)
        throw std::runtime_error("failed to create fixture file: " + full_path);

    out << content;
    out.close();

    return full_path;
}

std::string read_file(const std::string &path)
{
    std::ifstream in(path, std::ios::binary);

    if (!in)
        throw std::runtime_error("failed to open file for reading: " + path);

    std::ostringstream buffer;
    buffer << in.rdbuf();

    return buffer.str();
}

} // namespace nshtest
