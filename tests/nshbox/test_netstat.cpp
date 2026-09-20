// Exercises nshbox's netstat against a listening socket this test process
// opens itself - a single, known, controlled socket rather than the
// container's own constantly-changing socket table, the same idea
// test_ps.cpp/test_pstree.cpp use with BackgroundProcess. Port 0 lets the
// kernel pick a free port (no clash with anything the user runs on a
// well-known port), and the test process itself is the socket's owner, so
// the expected pid is simply getpid().
//
// SOCK_CLOEXEC matters: without it every child this harness forks (nshbox
// itself included) would inherit the listening fd, and netstat's
// inode -> pid lookup could legitimately report the child rather than
// this process.
#include "framework.hpp"
#include "run_command.hpp"

#include <stdexcept>
#include <string>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

using nshtest::run_command;
using nshtest::nshbox_path;

namespace {

class Listener
{
public:
    Listener()
    {
        fd_ = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);

        if (fd_ < 0)
            throw std::runtime_error("socket() failed");

        struct sockaddr_in addr = {};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;

        socklen_t len = sizeof(addr);

        if (bind(fd_, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) != 0 ||
            listen(fd_, 1) != 0 ||
            getsockname(fd_, reinterpret_cast<struct sockaddr *>(&addr), &len) != 0) {
            close(fd_);
            throw std::runtime_error("could not set up the test listener");
        }

        port_ = ntohs(addr.sin_port);
    }

    ~Listener() { close(fd_); }

    Listener(const Listener &) = delete;
    Listener &operator=(const Listener &) = delete;

    int port() const { return port_; }

private:
    int fd_ = -1;
    int port_ = 0;
};

// The flat JSON object for this listener's port, as a raw substring -
// same lightweight "find the closing brace" scan test_ps.cpp uses, valid
// because nothing nshbox emits nests objects.
std::string find_object(const std::string &json_array, int port)
{
    std::string marker = "\"local_port\":" + std::to_string(port) + ",";
    size_t pos = json_array.find(marker);

    if (pos == std::string::npos)
        throw std::runtime_error("port " + std::to_string(port) + " not found in netstat --json output");

    size_t start = json_array.rfind('{', pos);
    size_t end = json_array.find('}', pos);

    if (start == std::string::npos || end == std::string::npos)
        throw std::runtime_error("malformed netstat --json output");

    return json_array.substr(start, end - start + 1);
}

} // namespace

TEST_CASE(NetstatJsonDescribesListener, "netstat -l --json: a known listener has the right address/port/state/pid")
{
    Listener listener;

    auto out = run_command(nshbox_path(), {"netstat", "-l", "--json"});
    std::string object = find_object(out.stdout_data, listener.port());

    ASSERT_TRUE(out.exit_code == 0, "netstat --json must exit 0");
    ASSERT_TRUE(out.stdout_data.rfind("[{", 0) == 0, "netstat --json output is a JSON array of objects");
    ASSERT_TRUE(object.find("\"proto\":\"tcp\",") != std::string::npos, "proto field");
    ASSERT_TRUE(object.find("\"local_address\":\"127.0.0.1\",") != std::string::npos, "local_address field");
    ASSERT_TRUE(object.find("\"remote_address\":\"0.0.0.0\",\"remote_port\":0,") != std::string::npos,
                "a listener's remote side is 0.0.0.0:0");
    ASSERT_TRUE(object.find("\"state\":\"LISTEN\",") != std::string::npos, "state field");
    ASSERT_TRUE(object.find("\"pid\":" + std::to_string(getpid()) + ",") != std::string::npos,
                "pid is this test process, the socket's real owner");
    ASSERT_TRUE(object.find("\"process\":\"") != std::string::npos, "process key is always present");
}

TEST_CASE(NetstatJsonPretty, "netstat --JSON: pretty-printed, still contains the known listener")
{
    Listener listener;

    // Not diffed against "--json | nshbox json": other sockets on the
    // machine can come and go between two separate runs, so the whole
    // array is not stable - the generic --JSON/--json equivalence is
    // already covered by test_json.cpp.
    auto pretty = run_command(nshbox_path(), {"netstat", "-l", "--JSON"});

    ASSERT_TRUE(pretty.exit_code == 0, "netstat --JSON must exit 0");
    ASSERT_TRUE(pretty.stdout_data.rfind("[\n  {\n", 0) == 0, "--JSON output is pretty-printed");
    ASSERT_TRUE(pretty.stdout_data.find("\"local_port\": " + std::to_string(listener.port()) + ",") != std::string::npos,
                "pretty output contains this listener");
}

TEST_CASE(NetstatPlainListsListener, "netstat -l: plain output still lists a known listener")
{
    Listener listener;

    auto out = run_command(nshbox_path(), {"netstat", "-l"});

    ASSERT_TRUE(out.exit_code == 0, "netstat -l must exit 0");
    ASSERT_TRUE(out.stdout_data.find("127.0.0.1:" + std::to_string(listener.port())) != std::string::npos,
                "plain output contains the listener's address:port");
    ASSERT_TRUE(out.stdout_data.find("LISTEN") != std::string::npos, "plain output contains the LISTEN state");
}

TEST_CASE(NetstatRejectsUnknownOption, "netstat: an unknown option is rejected, --json or not")
{
    auto out = run_command(nshbox_path(), {"netstat", "--json", "-x"});

    ASSERT_TRUE(out.exit_code != 0, "unknown option must fail");
}
