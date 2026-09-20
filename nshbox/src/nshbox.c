/*
 * nshbox - tiny Linux toolbox
 *
 * Initially written for the Ulanzi TC002 / FlyThings Linux.
 *
 * Dynamically linked against libcrypto (OpenSSL's EVP interface) for the
 * checksum commands (sha256sum, sha1sum, sha384sum, sha512sum, md5sum) - the device
 * needs libcrypto.so.1.1 present at runtime as a result. Every other
 * command here is libc-only; this was a deliberate, separately-reviewed
 * tradeoff, not something to grow casually - see nshbox/README.md.
 *
 * Deliberately no SHA3 commands: confirmed on-device that the TC002's real
 * libcrypto.so.1.1 predates OpenSSL 1.1.1 (EVP_sha3_*() needs 1.1.1+), and
 * referencing them anywhere in this binary made the whole thing refuse to
 * start - see nshbox/README.md. Stick to OpenSSL 1.1.0-or-earlier API.
 *
 * Build:
 *   arm-linux-gnueabihf-gcc -Os -Wall -Wextra -o nshbox nshbox.c -lcrypto
 *   arm-linux-gnueabihf-strip nshbox
 *
 * Usage:
 *   nshbox --version | -v
 *   nshbox sysinfo [--json]
 *   nshbox ps [--json]
 *   nshbox pstree [-a] [pid]
 *   nshbox free
 *   nshbox vmstat [delay [count]]
 *   nshbox iostat [delay [count]]
 *   nshbox top [-m] [-l lines] [delay [count]]
 *   nshbox netstat [-l] [--json]
 *   nshbox readlink [-f] <path>
 *   nshbox realpath <path> [...]
 *   nshbox grep [-invqcErl] pattern [file ...]
 *   nshbox strings [-n min] [file ...]
 *   nshbox hexdump [file]
 *   nshbox file [-bL] file ...
 *   nshbox stat [--json] <file> [...]
 *   nshbox head [-n lines] [file ...]
 *   nshbox tail [-n lines] [file ...]
 *   nshbox wc [-lwc] [file ...]
 *   nshbox sort [-rnu] [file ...]
 *   nshbox tee [-a] [file ...]
 *   nshbox which <command> [...]
 *   nshbox clear
 *   nshbox sleep SECONDS
 *   nshbox uptime [--json]
 *   nshbox du [-hsb] [--json] [path ...]
 *   nshbox sha256sum [--json] [file ...]
 *   nshbox sha1sum [--json] [file ...]
 *   nshbox sha384sum [--json] [file ...]
 *   nshbox sha512sum [--json] [file ...]
 *   nshbox md5sum [--json] [file ...]
 *   nshbox base64 [-d] [-u] [-w cols] [file]
 *   nshbox jwt [--all|--header] [token]
 *   nshbox json [file]
 *   nshbox ldd [file ...]
 *   nshbox hostname [-f]
 *   nshbox dig [--json] <name> [A|CNAME|MX|TXT]
 *   nshbox nslookup [--json] [-type=A|CNAME|MX|TXT] <name>
 *   nshbox find [path ...] [-name pattern] [-type f|d|l] [-maxdepth n] [--json]
 *   nshbox tree [-L level] [path]
 *   nshbox tar -c|-x|-t[z] -f archive [-C dir] [path ...]
 *   nshbox iotest -w <file> <size>[K|M|G] [cap[K|M|G]]
 *   nshbox iotest -w <file> -t <seconds> <cap>[K|M|G]
 *   nshbox iotest -w <file> -n <rounds> <cap>[K|M|G]
 *   nshbox iotest -r <file>
 *   nshbox install [-f] [-q]
 */

#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <unistd.h>
#include <dirent.h>
#include <regex.h>
#include <sys/stat.h>
#include <time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <sys/statvfs.h>
#include <netinet/in.h>
#include <fnmatch.h>
#include <fcntl.h>
#include <openssl/evp.h>
#include <arpa/inet.h>
#include <arpa/nameser.h>
#include <resolv.h>
#include <netdb.h>


#define NSHBOX_VERSION    "0.6"


typedef int (*command_func_t)(int argc, char **argv);

typedef struct {
    const char     *name;
    command_func_t func;
    const char     *help;
} command_t;

typedef struct {
    uint32_t      local_address;
    unsigned int  local_port;
    uint32_t      remote_address;
    unsigned int  remote_port;
    unsigned int  state;
    unsigned long inode;
} tcp_socket_t;


/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

static const char *program_name(const char *path)
{
    const char *p;

    p = strrchr(path, '/');

    return p ? p + 1 : path;
}


static int is_number(const char *s)
{
    if (!s || !*s)
        return 0;

    while (*s) {
        if (!isdigit((unsigned char)*s))
            return 0;

        s++;
    }

    return 1;
}


static void read_cmdline(int pid, char *buf, size_t size)
{
    char path[64];
    FILE *f;
    size_t n;
    size_t i;

    if (!buf || size == 0)
        return;

    buf[0] = '\0';

    snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);

    f = fopen(path, "rb");

    if (!f) {
        snprintf(buf, size, "?");
        return;
    }

    n = fread(buf, 1, size - 1, f);
    fclose(f);

    if (n == 0) {
        /*
         * Kernel threads have an empty cmdline.
         * Try /proc/PID/comm.
         */

        snprintf(path, sizeof(path), "/proc/%d/comm", pid);

        f = fopen(path, "r");

        if (!f) {
            snprintf(buf, size, "?");
            return;
        }

        if (!fgets(buf, (int)size, f))
            snprintf(buf, size, "?");

        fclose(f);

        buf[strcspn(buf, "\r\n")] = '\0';

        return;
    }

    buf[n] = '\0';

    for (i = 0; i < n; i++) {
        if (buf[i] == '\0')
            buf[i] = ' ';
    }

    while (n > 0 && buf[n - 1] == ' ')
        buf[--n] = '\0';
}


static void format_ipv4(uint32_t address, char *buf, size_t size)
{
    snprintf(
        buf,
        size,
        "%u.%u.%u.%u",
        address & 0xff,
        (address >> 8) & 0xff,
        (address >> 16) & 0xff,
        (address >> 24) & 0xff
    );
}


static const char *tcp_state_name(unsigned int state)
{
    switch (state) {
        case 0x01: return "ESTABLISHED";
        case 0x02: return "SYN_SENT";
        case 0x03: return "SYN_RECV";
        case 0x04: return "FIN_WAIT1";
        case 0x05: return "FIN_WAIT2";
        case 0x06: return "TIME_WAIT";
        case 0x07: return "CLOSE";
        case 0x08: return "CLOSE_WAIT";
        case 0x09: return "LAST_ACK";
        case 0x0A: return "LISTEN";
        case 0x0B: return "CLOSING";
        default:   return "UNKNOWN";
    }
}


/* ------------------------------------------------------------------ */
/* Socket -> PID mapping                                              */
/* ------------------------------------------------------------------ */

static int find_socket_pid(unsigned long inode)
{
    DIR *proc;
    struct dirent *entry;
    char expected[64];

    snprintf(expected, sizeof(expected), "socket:[%lu]", inode);

    proc = opendir("/proc");

    if (!proc)
        return -1;

    while ((entry = readdir(proc)) != NULL) {
        DIR *fds;
        struct dirent *fd;
        /* "/proc/" (6) + up to NAME_MAX (255) + "/fd" (3) + NUL (1) */
        char fd_dir[6 + 255 + 3 + 1];

        if (!is_number(entry->d_name))
            continue;

        snprintf(
            fd_dir,
            sizeof(fd_dir),
            "/proc/%s/fd",
            entry->d_name
        );

        fds = opendir(fd_dir);

        if (!fds)
            continue;

        while ((fd = readdir(fds)) != NULL) {
            char path[PATH_MAX];
            char link[256];
            ssize_t len;

            if (fd->d_name[0] == '.')
                continue;

            snprintf(
                path,
                sizeof(path),
                "%s/%s",
                fd_dir,
                fd->d_name
            );

            len = readlink(path, link, sizeof(link) - 1);

            if (len < 0)
                continue;

            link[len] = '\0';

            if (strcmp(link, expected) == 0) {
                int pid = atoi(entry->d_name);

                closedir(fds);
                closedir(proc);

                return pid;
            }
        }

        closedir(fds);
    }

    closedir(proc);

    return -1;
}


/* ------------------------------------------------------------------ */
/* /proc/net/tcp parser                                               */
/* ------------------------------------------------------------------ */

static int parse_tcp_line(const char *line, tcp_socket_t *sock)
{
    unsigned int local_address;
    unsigned int local_port;
    unsigned int remote_address;
    unsigned int remote_port;
    unsigned int state;

    unsigned int uid;
    unsigned long inode;

    /*
     * Example:
     *
     * 2: 00000000:0050 00000000:0000 0A
     *    00000000:00000000 00:00000000 00000000
     *    0 0 136 ...
     */

    int fields = sscanf(
        line,
        "%*d: "
        "%8X:%4X "
        "%8X:%4X "
        "%2X "
        "%*s "
        "%*s "
        "%*s "
        "%u "
        "%*u "
        "%lu",
        &local_address,
        &local_port,
        &remote_address,
        &remote_port,
        &state,
        &uid,
        &inode
    );

    (void)uid;

    if (fields != 7)
        return -1;

    sock->local_address  = local_address;
    sock->local_port     = local_port;
    sock->remote_address = remote_address;
    sock->remote_port    = remote_port;
    sock->state          = state;
    sock->inode          = inode;

    return 0;
}


/* ------------------------------------------------------------------ */
/* netstat                                                            */
/* ------------------------------------------------------------------ */

static void json_print_string(const char *s);

static int cmd_netstat(int argc, char **argv)
{
    FILE *f;
    char line[512];
    int listeners_only = 0;
    int json = 0;
    int first = 1;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-l") == 0) {
            listeners_only = 1;
        } else if (strcmp(argv[i], "--json") == 0) {
            json = 1;
        } else {
            fprintf(stderr, "Usage: nshbox netstat [-l] [--json]\n");
            return 1;
        }
    }

    f = fopen("/proc/net/tcp", "r");

    if (!f) {
        perror("/proc/net/tcp");
        return 1;
    }

    /* Header */
    if (!fgets(line, sizeof(line), f)) {
        fclose(f);
        return 1;
    }

    if (json)
        putchar('[');
    else
        printf(
            "%-6s %-22s %-22s %-13s %-8s %-6s %s\n",
            "PROTO",
            "LOCAL",
            "REMOTE",
            "STATE",
            "INODE",
            "PID",
            "PROCESS"
        );

    while (fgets(line, sizeof(line), f)) {
        tcp_socket_t sock;

        char local_ip[32];
        char remote_ip[32];

        char local[64];
        char remote[64];

        char process[256];

        int pid;

        if (parse_tcp_line(line, &sock) != 0)
            continue;

        if (listeners_only && sock.state != 0x0A)
            continue;

        format_ipv4(
            sock.local_address,
            local_ip,
            sizeof(local_ip)
        );

        format_ipv4(
            sock.remote_address,
            remote_ip,
            sizeof(remote_ip)
        );

        if (json) {
            /* Address and port as separate fields - a consumer would
             * otherwise have to split "ip:port" itself. pid/process
             * follow this project's --json missing-value rule (see
             * sysinfo): key always present, "" when unknown, never
             * null or 0. read_cmdline()'s own "?" placeholder for an
             * unreadable /proc entry counts as unknown here too. */
            char cmd[256];

            pid = find_socket_pid(sock.inode);
            cmd[0] = '\0';

            if (pid >= 0)
                read_cmdline(pid, cmd, sizeof(cmd));

            if (!first)
                putchar(',');
            first = 0;

            printf("{\"proto\":\"tcp\",\"local_address\":\"%s\",\"local_port\":%u,"
                   "\"remote_address\":\"%s\",\"remote_port\":%u,"
                   "\"state\":\"%s\",\"inode\":%lu,\"pid\":",
                   local_ip, sock.local_port,
                   remote_ip, sock.remote_port,
                   tcp_state_name(sock.state), sock.inode);

            if (pid >= 0)
                printf("%d", pid);
            else
                fputs("\"\"", stdout);

            fputs(",\"process\":", stdout);
            json_print_string(strcmp(cmd, "?") == 0 ? "" : cmd);
            putchar('}');
            continue;
        }

        snprintf(
            local,
            sizeof(local),
            "%s:%u",
            local_ip,
            sock.local_port
        );

        snprintf(
            remote,
            sizeof(remote),
            "%s:%u",
            remote_ip,
            sock.remote_port
        );

        pid = find_socket_pid(sock.inode);

        if (pid >= 0)
            read_cmdline(pid, process, sizeof(process));
        else
            snprintf(process, sizeof(process), "?");

        printf(
            "%-6s %-22s %-22s %-13s %-8lu ",
            "tcp",
            local,
            remote,
            tcp_state_name(sock.state),
            sock.inode
        );

        if (pid >= 0)
            printf("%-6d %s\n", pid, process);
        else
            printf("%-6s %s\n", "-", process);
    }

    fclose(f);

    if (json)
        fputs("]\n", stdout);

    return 0;
}


/* ------------------------------------------------------------------ */
/* ps                                                                 */
/* ------------------------------------------------------------------ */

/* PPID is the field right after the single-char state; utime/stime
 * (accumulated CPU time, for the TIME column) follow ten fields later -
 * same "skip past the last ')'" approach used elsewhere in this file,
 * since comm can contain spaces or parens. */
static int read_proc_ppid_ticks(int pid, int *ppid, unsigned long long *ticks)
{
    char path[64];
    char buf[512];
    FILE *f;
    size_t n;
    char *close_paren;
    unsigned long long utime, stime;

    *ppid = -1;
    *ticks = 0;

    snprintf(path, sizeof(path), "/proc/%d/stat", pid);

    f = fopen(path, "r");

    if (!f)
        return 1;

    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);

    if (n == 0)
        return 1;

    buf[n] = '\0';

    close_paren = strrchr(buf, ')');

    if (!close_paren)
        return 1;

    if (sscanf(close_paren + 2,
               "%*c %d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu",
               ppid, &utime, &stime) != 3)
        return 1;

    *ticks = utime + stime;

    return 0;
}

/* Shared by every --json command in this file (ps, du, dig, nslookup) -
 * one JSON string escaper, not a separately-maintained copy per command,
 * since there is no reason for them to ever disagree - the same
 * reasoning already applied across binaries for tc002-discover.c's own,
 * separate print_json_string(). Moved here, ahead of ps (the earliest
 * command needing it), rather than left where DNS's own copy used to
 * live further down. */
static void json_print_string(const char *s)
{
    const unsigned char *p = (const unsigned char *)s;

    putchar('"');

    while (*p) {
        switch (*p) {
            case '"':  fputs("\\\"", stdout); break;
            case '\\': fputs("\\\\", stdout); break;
            case '\b': fputs("\\b", stdout); break;
            case '\f': fputs("\\f", stdout); break;
            case '\n': fputs("\\n", stdout); break;
            case '\r': fputs("\\r", stdout); break;
            case '\t': fputs("\\t", stdout); break;
            default:
                if (*p < 0x20)
                    printf("\\u%04x", *p);
                else
                    putchar(*p);
                break;
        }
        p++;
    }

    putchar('"');
}

/* Shared by ps and top - accumulated CPU time (utime+stime, in clock
 * ticks) as HH:MM:SS, the same style ps traditionally uses. Hours are
 * not capped at 99 - a long-running process just gets a wider field. */
static void format_cpu_time(unsigned long long ticks, long clk_tck, char *buf, size_t buf_len)
{
    long long total_seconds;
    long long hours, minutes, seconds;

    total_seconds = (clk_tck > 0) ? (long long)(ticks / (unsigned long long)clk_tck) : 0;

    hours = total_seconds / 3600;
    minutes = (total_seconds % 3600) / 60;
    seconds = total_seconds % 60;

    snprintf(buf, buf_len, "%02lld:%02lld:%02lld", hours, minutes, seconds);
}

/* Defined later in the file alongside top's process-snapshot code;
 * forward-declared here rather than duplicated, since ps needs the exact
 * same /proc/<pid>/status VmRSS reading. */
static unsigned long long read_proc_rss_kb(int pid);

static int cmd_ps(int argc, char **argv)
{
    DIR *proc;
    struct dirent *entry;
    long clk_tck;
    int json = 0;
    int first = 1;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) {
            json = 1;
        } else {
            fprintf(stderr, "Usage: nshbox ps [--json]\n");
            return 2;
        }
    }

    clk_tck = sysconf(_SC_CLK_TCK);

    if (clk_tck < 1)
        clk_tck = 100;

    proc = opendir("/proc");

    if (!proc) {
        perror("/proc");
        return 1;
    }

    if (json)
        putchar('[');
    else
        printf("%-7s %-7s %10s  %-10s %s\n", "PID", "PPID", "RSS(kB)", "TIME", "COMMAND");

    while ((entry = readdir(proc)) != NULL) {
        char cmdline[256];
        char time_str[32];
        int pid;
        int ppid = -1;
        unsigned long long ticks = 0;
        unsigned long long rss_kb;

        if (!is_number(entry->d_name))
            continue;

        pid = atoi(entry->d_name);
        rss_kb = read_proc_rss_kb(pid);

        read_proc_ppid_ticks(pid, &ppid, &ticks);
        format_cpu_time(ticks, clk_tck, time_str, sizeof(time_str));
        read_cmdline(pid, cmdline, sizeof(cmdline));

        if (json) {
            if (!first)
                putchar(',');
            first = 0;

            printf("{\"pid\":%d,\"ppid\":%d,\"rss_kb\":%llu,\"rss_bytes\":%llu,"
                   "\"time\":\"%s\",\"time_seconds\":%llu,\"command\":",
                   pid, ppid, rss_kb, rss_kb * 1024,
                   time_str, ticks / (unsigned long long)clk_tck);
            json_print_string(cmdline);
            putchar('}');
        } else {
            printf("%-7d %-7d %10llu  %-10s %s\n", pid, ppid, rss_kb, time_str, cmdline);
        }
    }

    closedir(proc);

    if (json)
        fputs("]\n", stdout);

    return 0;
}


/* ------------------------------------------------------------------ */
/* pstree                                                             */
/* ------------------------------------------------------------------ */

#define PSTREE_MAX_PROCS 512
#define PSTREE_MAX_DEPTH 64
#define PSTREE_MAX_CHILDREN 256
#define PSTREE_MAX_THREAD_GROUPS 64
#define PSTREE_PREFIX_MAX 512

typedef struct {
    int pid;
    int ppid;
    char name[64];
} pstree_proc_t;

/* A node in the fancy (box-drawing) renderer's per-level child list -
 * either a real child process, or a synthetic "N*[{name}]" pseudo-node
 * representing a group of this process's own same-named threads (from
 * /proc/<pid>/task/, not /proc/<pid>/stat's ppid - threads are not
 * separate top-level /proc/<pid> entries, so they need a second data
 * source pstree_proc_t never captures). */
typedef struct {
    int is_thread_group;
    int pid;
    char name[64];
    int thread_count;
} pstree_child_t;

/* PPID is the field right after the single-char state, same "skip past
 * the last ')'" approach as elsewhere in this file - comm can contain
 * spaces or parens, so it is not safe to just split on whitespace. */
static int read_proc_ppid_name(int pid, int *ppid, char *name, size_t name_len)
{
    char path[64];
    char buf[512];
    FILE *f;
    size_t n;
    char *open_paren;
    char *close_paren;
    char *rest;

    *ppid = -1;
    name[0] = '\0';

    snprintf(path, sizeof(path), "/proc/%d/stat", pid);

    f = fopen(path, "r");

    if (!f)
        return 1;

    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);

    if (n == 0)
        return 1;

    buf[n] = '\0';

    open_paren = strchr(buf, '(');
    close_paren = strrchr(buf, ')');

    if (!open_paren || !close_paren || close_paren < open_paren)
        return 1;

    {
        size_t len = (size_t)(close_paren - open_paren - 1);

        if (len >= name_len)
            len = name_len - 1;

        memcpy(name, open_paren + 1, len);
        name[len] = '\0';
    }

    rest = close_paren + 2;

    if (sscanf(rest, "%*c %d", ppid) != 1)
        return 1;

    return 0;
}

static void pstree_print_ascii(const pstree_proc_t *procs, int count, int pid, int depth)
{
    int i;

    if (depth > PSTREE_MAX_DEPTH)
        return;

    for (i = 0; i < count; i++) {
        int j;

        if (procs[i].ppid != pid || procs[i].pid == pid)
            continue;

        for (j = 0; j < depth; j++)
            fputs("  ", stdout);

        printf("%d %s\n", procs[i].pid, procs[i].name);

        pstree_print_ascii(procs, count, procs[i].pid, depth + 1);
    }
}

/* Only the name is needed here (the thread's own "ppid" field is not
 * meaningful for our purposes - its parent is already known to be the
 * process whose /proc/<pid>/task/ this came from), so this is a smaller,
 * separate reader rather than reusing read_proc_ppid_name's return shape. */
static int pstree_read_task_name(const char *stat_path, char *name, size_t name_len)
{
    char buf[512];
    FILE *f;
    size_t n;
    char *open_paren, *close_paren;

    name[0] = '\0';

    f = fopen(stat_path, "r");

    if (!f)
        return 1;

    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);

    if (n == 0)
        return 1;

    buf[n] = '\0';

    open_paren = strchr(buf, '(');
    close_paren = strrchr(buf, ')');

    if (!open_paren || !close_paren || close_paren < open_paren)
        return 1;

    {
        size_t len = (size_t)(close_paren - open_paren - 1);

        if (len >= name_len)
            len = name_len - 1;

        memcpy(name, open_paren + 1, len);
        name[len] = '\0';
    }

    return 0;
}

/* Walks /proc/<pid>/task/ (every thread of this process, including the
 * main one) and groups the extra threads - i.e. every task id except pid
 * itself, which is already represented by the process node - by name,
 * so e.g. 5 identically-named worker threads become one "5*[{name}]"
 * pseudo-child instead of 5 separate lines. */
static int pstree_get_thread_groups(int pid, pstree_child_t *groups, int max_groups)
{
    char path[64];
    DIR *task_dir;
    struct dirent *entry;
    int count = 0;

    snprintf(path, sizeof(path), "/proc/%d/task", pid);

    task_dir = opendir(path);

    if (!task_dir)
        return 0;

    while ((entry = readdir(task_dir)) != NULL) {
        int tid;
        char tpath[80];
        char name[64];
        int i;
        int found;

        if (!is_number(entry->d_name))
            continue;

        tid = atoi(entry->d_name);

        if (tid == pid)
            continue;

        snprintf(tpath, sizeof(tpath), "/proc/%d/task/%d/stat", pid, tid);

        if (pstree_read_task_name(tpath, name, sizeof(name)) != 0)
            continue;

        found = 0;

        for (i = 0; i < count; i++) {
            if (strcmp(groups[i].name, name) == 0) {
                groups[i].thread_count++;
                found = 1;
                break;
            }
        }

        if (!found && count < max_groups) {
            groups[count].is_thread_group = 1;
            groups[count].pid = 0;
            strncpy(groups[count].name, name, sizeof(groups[count].name) - 1);
            groups[count].name[sizeof(groups[count].name) - 1] = '\0';
            groups[count].thread_count = 1;
            count++;
        }
    }

    closedir(task_dir);

    return count;
}

static void pstree_print_node(const pstree_proc_t *procs, int proc_count,
                              const pstree_child_t *node, const char *prefix, int depth);

/* Builds this pid's list of display children (real child processes, in
 * /proc enumeration order, followed by this process's own thread
 * groups) and prints them using the real pstree's own layout rule: a
 * single child continues on the current line (no new indent level - a
 * chain of single-child processes stays on one line); with more than
 * one child, the first continues the current line via "-+-" and every
 * further sibling starts a new line under the accumulated prefix, using
 * "|-" or the last sibling's "`-". */
static void pstree_print_children(const pstree_proc_t *procs, int proc_count, int pid,
                                  const char *prefix, int depth)
{
    /* NOT static, and heap-allocated rather than a plain stack array:
       this function recurses (via pstree_print_node() below, for every
       child that itself has children). A static array here would be one
       shared buffer across every recursive call at every depth - the
       outer call's own children[] would be silently overwritten by a
       nested call's own use of it before the outer call's own "for" loop
       below finishes reading from it, corrupting later siblings' names/
       pids whenever an earlier sibling has children of its own
       (confirmed directly, 2026-09-14 - a real, common shape for any
       process tree where one child forks its own workers, followed by
       more siblings). A plain non-static stack array avoids that
       aliasing but is not free either: PSTREE_MAX_CHILDREN *
       sizeof(pstree_child_t) is tens of KB, which at PSTREE_MAX_DEPTH
       levels of recursion adds up to over a megabyte of stack - fine on
       a normal host, less certain on the TC002's own constrained
       embedded environment (this runs there too, via nshbox itself) -
       so heap allocation here, same reasoning already applied to the
       tree command's own per-directory entries array (see tree_walk()
       above), stays the more conservative choice for code that also
       has to run on-device. */
    pstree_child_t *children;
    int nchildren = 0;
    int i;

    if (depth > PSTREE_MAX_DEPTH)
        return;

    children = malloc(PSTREE_MAX_CHILDREN * sizeof(*children));

    if (!children) {
        perror("pstree: malloc");
        return;
    }

    for (i = 0; i < proc_count && nchildren < PSTREE_MAX_CHILDREN; i++) {
        if (procs[i].ppid != pid || procs[i].pid == pid)
            continue;

        children[nchildren].is_thread_group = 0;
        children[nchildren].pid = procs[i].pid;
        children[nchildren].thread_count = 0;
        strncpy(children[nchildren].name, procs[i].name, sizeof(children[nchildren].name) - 1);
        children[nchildren].name[sizeof(children[nchildren].name) - 1] = '\0';
        nchildren++;
    }

    {
        pstree_child_t groups[PSTREE_MAX_THREAD_GROUPS];
        int ngroups = pstree_get_thread_groups(pid, groups, PSTREE_MAX_THREAD_GROUPS);
        int g;

        for (g = 0; g < ngroups && nchildren < PSTREE_MAX_CHILDREN; g++)
            children[nchildren++] = groups[g];
    }

    if (nchildren == 0) {
        free(children);
        return;
    }

    if (nchildren == 1) {
        /* Three characters wide ("---"), matching the branching
           connector's own width ("-+-") below - confirmed directly
           against real pstree (2026-09-14): it uses the same total
           connector width whether a process has one child or several,
           so a later branch point deeper in a chain of single-child
           hops still lines up correctly (see the prefix-extension
           comment in pstree_print_node() below, which depends on this
           width matching what it assumes). nshbox's own previous
           single-character connector broke that assumption. */
        char child_prefix[PSTREE_PREFIX_MAX];
        size_t prefix_len = strlen(prefix);

        fputs("\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80", stdout); /* U+2500 x3 */

        /* prefix already carries a "+1" credit from the caller's own
           pstree_print_node() (calibrated for the BRANCHING connector's
           width, where the next line's branch marker lands 1 column
           past the parent's own name) - this connector is 3 columns
           wide, not 1, so 2 more spaces complete that credit before
           this child's own name starts printing. Confirmed directly:
           without this, a chain of single-child hops (sh -> sh -> a
           later branch) under-indented that branch's own continuation
           lines by exactly this gap. */
        if (prefix_len + 2 < sizeof(child_prefix)) {
            memcpy(child_prefix, prefix, prefix_len);
            child_prefix[prefix_len] = ' ';
            child_prefix[prefix_len + 1] = ' ';
            child_prefix[prefix_len + 2] = '\0';
            pstree_print_node(procs, proc_count, &children[0], child_prefix, depth + 1);
        } else {
            pstree_print_node(procs, proc_count, &children[0], prefix, depth + 1);
        }

        free(children);
        return;
    }

    fputs("\xe2\x94\x80\xe2\x94\xac\xe2\x94\x80", stdout); /* -+- */

    {
        char child_prefix[PSTREE_PREFIX_MAX];

        snprintf(child_prefix, sizeof(child_prefix), "%s\xe2\x94\x82 ", prefix); /* prefix + "| " */
        pstree_print_node(procs, proc_count, &children[0], child_prefix, depth + 1);
    }

    for (i = 1; i < nchildren; i++) {
        int is_last = (i == nchildren - 1);
        char child_prefix[PSTREE_PREFIX_MAX];

        /* "\n" + prefix + branch connector (|- or `-) */
        printf("\n%s%s", prefix, is_last ? "\xe2\x94\x94\xe2\x94\x80" : "\xe2\x94\x9c\xe2\x94\x80");

        snprintf(child_prefix, sizeof(child_prefix), "%s%s", prefix, is_last ? "  " : "\xe2\x94\x82 ");
        pstree_print_node(procs, proc_count, &children[i], child_prefix, depth + 1);
    }

    free(children);
}

static void pstree_print_node(const pstree_proc_t *procs, int proc_count,
                              const pstree_child_t *node, const char *prefix, int depth)
{
    if (node->is_thread_group) {
        if (node->thread_count > 1)
            printf("%d*[{%s}]", node->thread_count, node->name);
        else
            printf("{%s}", node->name);

        return;
    }

    printf("%s", node->name);

    /* Any further sibling lines pstree_print_children() prints below
       this node (when it has more than one child of its own) must start
       past everything already printed on THIS line so far - this node's
       own name, plus one column for the connector's own leading "-"
       (both the single-child "---" and the branching "-+-" connectors
       start with exactly one "-" before anything else, so this offset is
       the same either way - see pstree_print_children()'s own comment).
       Extending prefix here, not in pstree_print_children(), is what
       makes a whole chain of single-child hops accumulate correctly: a
       name printed at one level becomes part of the fixed left margin
       for every level below it, the same way real pstree's own output
       lines up. Confirmed directly against real "pstree -Uc" (2026-09-14):
       nshbox's own prefix previously never grew past whatever a
       branch/depth passed down, so a second-or-later sibling's line
       started at column 0 instead of underneath its own branch point. */
    {
        char extended_prefix[PSTREE_PREFIX_MAX];
        size_t prefix_len = strlen(prefix);
        size_t pad = strlen(node->name) + 1;

        if (prefix_len + pad >= sizeof(extended_prefix)) {
            /* Would overflow the prefix buffer (an extremely deep or
               wide tree) - fall back to the unextended prefix rather
               than truncating mid-buffer; alignment degrades gracefully
               instead of risking a bad snprintf() elsewhere. */
            pstree_print_children(procs, proc_count, node->pid, prefix, depth);
            return;
        }

        memcpy(extended_prefix, prefix, prefix_len);
        memset(extended_prefix + prefix_len, ' ', pad);
        extended_prefix[prefix_len + pad] = '\0';

        pstree_print_children(procs, proc_count, node->pid, extended_prefix, depth);
    }
}

static int cmd_pstree(int argc, char **argv)
{
    static pstree_proc_t procs[PSTREE_MAX_PROCS];
    DIR *proc;
    struct dirent *entry;
    int count = 0;
    int root = 1;
    int ascii = 0;
    int arg = 1;
    int i;
    int root_found = 0;
    int root_index = -1;

    while (arg < argc && strcmp(argv[arg], "-a") == 0) {
        ascii = 1;
        arg++;
    }

    if (argc - arg > 1) {
        fprintf(stderr, "Usage: nshbox pstree [-a] [pid]\n");
        return 1;
    }

    if (arg < argc) {
        char *end;

        errno = 0;
        root = (int)strtol(argv[arg], &end, 10);

        if (errno || *end || root < 1) {
            fprintf(stderr, "pstree: invalid pid: %s\n", argv[arg]);
            return 1;
        }
    }

    proc = opendir("/proc");

    if (!proc) {
        perror("/proc");
        return 1;
    }

    while (count < PSTREE_MAX_PROCS && (entry = readdir(proc)) != NULL) {
        int pid;

        if (!is_number(entry->d_name))
            continue;

        pid = atoi(entry->d_name);

        if (read_proc_ppid_name(pid, &procs[count].ppid, procs[count].name,
                                sizeof(procs[count].name)) != 0)
            continue;

        procs[count].pid = pid;
        count++;
    }

    closedir(proc);

    for (i = 0; i < count; i++) {
        if (procs[i].pid == root) {
            root_found = 1;
            root_index = i;
            break;
        }
    }

    if (!root_found) {
        fprintf(stderr, "pstree: pid %d not found\n", root);
        return 1;
    }

    if (ascii) {
        printf("%d %s\n", procs[root_index].pid, procs[root_index].name);
        pstree_print_ascii(procs, count, root, 1);
    } else {
        pstree_child_t root_node;

        root_node.is_thread_group = 0;
        root_node.pid = root;
        root_node.thread_count = 0;
        strncpy(root_node.name, procs[root_index].name, sizeof(root_node.name) - 1);
        root_node.name[sizeof(root_node.name) - 1] = '\0';

        pstree_print_node(procs, count, &root_node, "", 1);
        printf("\n");
    }

    return 0;
}


/* ------------------------------------------------------------------ */
/* free                                                               */
/* ------------------------------------------------------------------ */

static int cmd_free(int argc, char **argv)
{
    FILE *f;
    char line[256];

    (void)argc;
    (void)argv;

    f = fopen("/proc/meminfo", "r");

    if (!f) {
        perror("/proc/meminfo");
        return 1;
    }

    while (fgets(line, sizeof(line), f))
        fputs(line, stdout);

    fclose(f);

    return 0;
}


/* ------------------------------------------------------------------ */
/* vmstat                                                             */
/* ------------------------------------------------------------------ */

typedef struct {
    unsigned long long user, nice, system, idle, iowait, irq, softirq, steal;
} cpu_stat_t;

static int read_cpu_stat(cpu_stat_t *out)
{
    FILE *f;
    char line[256];
    int found = 0;

    memset(out, 0, sizeof(*out));

    f = fopen("/proc/stat", "r");

    if (!f) {
        perror("/proc/stat");
        return 1;
    }

    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "cpu ", 4) == 0) {
            sscanf(
                line,
                "cpu %llu %llu %llu %llu %llu %llu %llu %llu",
                &out->user, &out->nice, &out->system, &out->idle,
                &out->iowait, &out->irq, &out->softirq, &out->steal
            );
            found = 1;
            break;
        }
    }

    fclose(f);

    return found ? 0 : 1;
}

static void read_stat_totals(unsigned long long *intr, unsigned long long *ctxt)
{
    FILE *f;
    char line[256];

    *intr = 0;
    *ctxt = 0;

    f = fopen("/proc/stat", "r");

    if (!f)
        return;

    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "intr ", 5) == 0)
            sscanf(line, "intr %llu", intr);
        else if (strncmp(line, "ctxt ", 5) == 0)
            sscanf(line, "ctxt %llu", ctxt);
    }

    fclose(f);
}

static void read_vmstat_counters(unsigned long long *pswpin, unsigned long long *pswpout,
                                 unsigned long long *pgpgin, unsigned long long *pgpgout)
{
    FILE *f;
    char line[256];

    *pswpin = 0;
    *pswpout = 0;
    *pgpgin = 0;
    *pgpgout = 0;

    f = fopen("/proc/vmstat", "r");

    if (!f)
        return;

    while (fgets(line, sizeof(line), f)) {
        sscanf(line, "pswpin %llu", pswpin);
        sscanf(line, "pswpout %llu", pswpout);
        sscanf(line, "pgpgin %llu", pgpgin);
        sscanf(line, "pgpgout %llu", pgpgout);
    }

    fclose(f);
}

static void read_meminfo_kb(const char *key, unsigned long long *value)
{
    FILE *f;
    char line[256];
    size_t keylen = strlen(key);

    *value = 0;

    f = fopen("/proc/meminfo", "r");

    if (!f)
        return;

    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, keylen) == 0 && line[keylen] == ':') {
            sscanf(line + keylen + 1, "%llu", value);
            break;
        }
    }

    fclose(f);
}

static void count_proc_states(unsigned long *running, unsigned long *blocked)
{
    DIR *proc;
    struct dirent *entry;

    *running = 0;
    *blocked = 0;

    proc = opendir("/proc");

    if (!proc)
        return;

    while ((entry = readdir(proc)) != NULL) {
        /* "/proc/" (6) + up to NAME_MAX (255) + "/stat" (5) + NUL (1) */
        char path[6 + 255 + 5 + 1];
        char buf[512];
        FILE *f;
        size_t n;
        char *close_paren;

        if (!is_number(entry->d_name))
            continue;

        snprintf(path, sizeof(path), "/proc/%s/stat", entry->d_name);

        f = fopen(path, "r");

        if (!f)
            continue;

        n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);

        if (n == 0)
            continue;

        buf[n] = '\0';

        /* "pid (comm) state ..." - comm can contain spaces/parens, so find
         * the LAST ')' rather than parsing fields left to right. */
        close_paren = strrchr(buf, ')');

        if (!close_paren || close_paren[1] != ' ')
            continue;

        switch (close_paren[2]) {
            case 'R': (*running)++; break;
            case 'D': (*blocked)++; break;
            default: break;
        }
    }

    closedir(proc);
}

static int parse_delay_count(int argc, char **argv, const char *usage_msg, long *delay, long *count)
{
    char *end;

    *delay = 1;
    *count = 1;

    if (argc >= 2) {
        errno = 0;
        *delay = strtol(argv[1], &end, 10);

        if (errno || *end || *delay < 1) {
            fprintf(stderr, "%s", usage_msg);
            return 1;
        }

        *count = -1; /* delay given, no count => repeat until interrupted */
    }

    if (argc >= 3) {
        errno = 0;
        *count = strtol(argv[2], &end, 10);

        if (errno || *end || *count < 1) {
            fprintf(stderr, "%s", usage_msg);
            return 1;
        }
    }

    if (argc > 3) {
        fprintf(stderr, "%s", usage_msg);
        return 1;
    }

    return 0;
}

static int cmd_vmstat(int argc, char **argv)
{
    static const char usage_msg[] = "Usage: nshbox vmstat [delay [count]]\n";

    cpu_stat_t cpu1, cpu2;
    unsigned long long intr1, ctxt1, intr2, ctxt2;
    unsigned long long pswpin1, pswpout1, pgpgin1, pgpgout1;
    unsigned long long pswpin2, pswpout2, pgpgin2, pgpgout2;
    unsigned long long mem_free, mem_buffers, mem_cached, swap_total, swap_free;
    unsigned long running, blocked;
    unsigned long long total1, total2, total_delta;
    unsigned long long user_d, sys_d, idle_d, iowait_d, steal_d;
    unsigned long long si, so, bi, bo, in_rate, cs_rate;
    long page_kb;
    double us, sy, id, wa, st;
    long delay, count, iteration;

    if (parse_delay_count(argc, argv, usage_msg, &delay, &count) != 0)
        return 1;

    printf("procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----\n");
    printf(" r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st\n");
    fflush(stdout);

    if (read_cpu_stat(&cpu1) != 0)
        return 1;

    read_stat_totals(&intr1, &ctxt1);
    read_vmstat_counters(&pswpin1, &pswpout1, &pgpgin1, &pgpgout1);

    /* Rates (cpu%, si/so, bi/bo, in, cs) need two samples - a single
     * /proc/stat read only gives cumulative counters since boot, which
     * average out to nearly nothing on a long-uptime device. */
    for (iteration = 0; count < 0 || iteration < count; iteration++) {
        sleep((unsigned int)delay);

        if (read_cpu_stat(&cpu2) != 0)
            return 1;

        read_stat_totals(&intr2, &ctxt2);
        read_vmstat_counters(&pswpin2, &pswpout2, &pgpgin2, &pgpgout2);

        count_proc_states(&running, &blocked);

        read_meminfo_kb("MemFree", &mem_free);
        read_meminfo_kb("Buffers", &mem_buffers);
        read_meminfo_kb("Cached", &mem_cached);
        read_meminfo_kb("SwapTotal", &swap_total);
        read_meminfo_kb("SwapFree", &swap_free);

        total1 = cpu1.user + cpu1.nice + cpu1.system + cpu1.idle +
                 cpu1.iowait + cpu1.irq + cpu1.softirq + cpu1.steal;
        total2 = cpu2.user + cpu2.nice + cpu2.system + cpu2.idle +
                 cpu2.iowait + cpu2.irq + cpu2.softirq + cpu2.steal;
        total_delta = (total2 > total1) ? (total2 - total1) : 1;

        user_d   = (cpu2.user + cpu2.nice) - (cpu1.user + cpu1.nice);
        sys_d    = (cpu2.system + cpu2.irq + cpu2.softirq) - (cpu1.system + cpu1.irq + cpu1.softirq);
        idle_d   = cpu2.idle - cpu1.idle;
        iowait_d = cpu2.iowait - cpu1.iowait;
        steal_d  = cpu2.steal - cpu1.steal;

        us = 100.0 * (double)user_d / (double)total_delta;
        sy = 100.0 * (double)sys_d / (double)total_delta;
        id = 100.0 * (double)idle_d / (double)total_delta;
        wa = 100.0 * (double)iowait_d / (double)total_delta;
        st = 100.0 * (double)steal_d / (double)total_delta;

        /* /proc/vmstat's pswpin/pswpout are in pages, pgpgin/pgpgout
         * already in KB - see Documentation/filesystems/proc.rst. */
        page_kb = sysconf(_SC_PAGESIZE) / 1024;

        if (page_kb < 1)
            page_kb = 4;

        si = (pswpin2 - pswpin1) * (unsigned long long)page_kb / (unsigned long long)delay;
        so = (pswpout2 - pswpout1) * (unsigned long long)page_kb / (unsigned long long)delay;
        bi = (pgpgin2 - pgpgin1) / (unsigned long long)delay;
        bo = (pgpgout2 - pgpgout1) / (unsigned long long)delay;
        in_rate = (intr2 - intr1) / (unsigned long long)delay;
        cs_rate = (ctxt2 - ctxt1) / (unsigned long long)delay;

        printf(
            "%2lu %2lu %6llu %6llu %6llu %6llu %4llu %4llu %5llu %5llu %4llu %4llu %2.0f %2.0f %2.0f %2.0f %2.0f\n",
            running, blocked,
            swap_total - swap_free, mem_free, mem_buffers, mem_cached,
            si, so, bi, bo,
            in_rate, cs_rate,
            us, sy, id, wa, st
        );
        fflush(stdout);

        cpu1 = cpu2;
        intr1 = intr2;
        ctxt1 = ctxt2;
        pswpin1 = pswpin2;
        pswpout1 = pswpout2;
        pgpgin1 = pgpgin2;
        pgpgout1 = pgpgout2;
    }

    return 0;
}


/* ------------------------------------------------------------------ */
/* iostat                                                             */
/* ------------------------------------------------------------------ */

#define IOSTAT_MAX_DEVICES 64

typedef struct {
    char name[64];
    unsigned long long reads_completed;
    unsigned long long reads_merged;
    unsigned long long sectors_read;
    unsigned long long time_reading_ms;
    unsigned long long writes_completed;
    unsigned long long writes_merged;
    unsigned long long sectors_written;
    unsigned long long time_writing_ms;
    unsigned long long io_ticks_ms;
    unsigned long long weighted_ticks_ms;
} diskstat_t;

static int read_diskstats(diskstat_t *devices, int max_devices)
{
    FILE *f;
    char line[256];
    int count = 0;

    f = fopen("/proc/diskstats", "r");

    if (!f) {
        perror("/proc/diskstats");
        return -1;
    }

    while (count < max_devices && fgets(line, sizeof(line), f)) {
        unsigned int major, minor;
        char name[64];
        unsigned long long reads_completed, reads_merged, sectors_read, time_reading;
        unsigned long long writes_completed, writes_merged, sectors_written, time_writing;
        unsigned long long ios_in_progress, io_ticks, weighted_ticks;
        int fields;

        /* /proc/diskstats: major minor name, then the 14 classic fields -
         * reads/writes completed/merged, sectors, time-spent-ms, ios in
         * progress, io_ticks (for %util), and weighted time-in-queue (for
         * aqu-sz). Newer kernels append discard/flush counters we don't
         * need - sscanf just stops once these 14 fields are filled.
         * Sector size is always 512 bytes here regardless of the
         * device's real block size - a documented kernel invariant, not
         * an assumption. */
        fields = sscanf(
            line,
            "%u %u %63s %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
            &major, &minor, name,
            &reads_completed, &reads_merged, &sectors_read, &time_reading,
            &writes_completed, &writes_merged, &sectors_written, &time_writing,
            &ios_in_progress, &io_ticks, &weighted_ticks
        );

        (void)major;
        (void)minor;
        (void)ios_in_progress;

        if (fields < 14)
            continue;

        strncpy(devices[count].name, name, sizeof(devices[count].name) - 1);
        devices[count].name[sizeof(devices[count].name) - 1] = '\0';
        devices[count].reads_completed = reads_completed;
        devices[count].reads_merged = reads_merged;
        devices[count].sectors_read = sectors_read;
        devices[count].time_reading_ms = time_reading;
        devices[count].writes_completed = writes_completed;
        devices[count].writes_merged = writes_merged;
        devices[count].sectors_written = sectors_written;
        devices[count].time_writing_ms = time_writing;
        devices[count].io_ticks_ms = io_ticks;
        devices[count].weighted_ticks_ms = weighted_ticks;
        count++;
    }

    fclose(f);

    return count;
}

static void print_iostat_header(void)
{
    printf(
        "%-13s %7s %7s %8s %8s %7s %7s %8s %8s %7s %6s\n",
        "Device", "r/s", "w/s", "rkB/s", "wkB/s", "rrqm/s", "wrqm/s",
        "r_await", "w_await", "aqu-sz", "%util"
    );
}

static int cmd_iostat(int argc, char **argv)
{
    static const char usage_msg[] = "Usage: nshbox iostat [delay [count]]\n";

    static diskstat_t before[IOSTAT_MAX_DEVICES];
    static diskstat_t after[IOSTAT_MAX_DEVICES];
    int before_count, after_count;
    long delay, count, iteration;
    int i, j;

    if (parse_delay_count(argc, argv, usage_msg, &delay, &count) != 0)
        return 1;

    before_count = read_diskstats(before, IOSTAT_MAX_DEVICES);

    if (before_count < 0)
        return 1;

    /* Same reasoning as vmstat: throughput/await/queue-size/%util only
     * mean something as a delta between two points in time - a single
     * /proc/diskstats read only gives cumulative counters since boot. */
    for (iteration = 0; count < 0 || iteration < count; iteration++) {
        sleep((unsigned int)delay);

        after_count = read_diskstats(after, IOSTAT_MAX_DEVICES);

        if (after_count < 0)
            return 1;

        if (iteration > 0)
            printf("\n");

        print_iostat_header();

        for (i = 0; i < after_count; i++) {
            unsigned long long reads_d = 0, writes_d = 0;
            unsigned long long reads_merged_d = 0, writes_merged_d = 0;
            unsigned long long sread_d = 0, swrite_d = 0;
            unsigned long long time_reading_d = 0, time_writing_d = 0;
            unsigned long long io_ticks_d = 0, weighted_ticks_d = 0;
            double r_await, w_await, aqu_sz, util;

            for (j = 0; j < before_count; j++) {
                if (strcmp(after[i].name, before[j].name) == 0) {
                    reads_d          = after[i].reads_completed   - before[j].reads_completed;
                    writes_d         = after[i].writes_completed  - before[j].writes_completed;
                    reads_merged_d   = after[i].reads_merged      - before[j].reads_merged;
                    writes_merged_d  = after[i].writes_merged     - before[j].writes_merged;
                    sread_d          = after[i].sectors_read      - before[j].sectors_read;
                    swrite_d         = after[i].sectors_written   - before[j].sectors_written;
                    time_reading_d   = after[i].time_reading_ms   - before[j].time_reading_ms;
                    time_writing_d   = after[i].time_writing_ms   - before[j].time_writing_ms;
                    io_ticks_d       = after[i].io_ticks_ms       - before[j].io_ticks_ms;
                    weighted_ticks_d = after[i].weighted_ticks_ms - before[j].weighted_ticks_ms;
                    break;
                }
            }

            /* await: average ms per completed I/O (service + queue time,
             * approximated the same way sysstat derives it from
             * /proc/diskstats - not a separately measured queue wait). */
            r_await = reads_d  ? (double)time_reading_d / (double)reads_d  : 0.0;
            w_await = writes_d ? (double)time_writing_d / (double)writes_d : 0.0;

            /* aqu-sz: time-weighted average number of I/Os in flight.
             * %util: percentage of the interval the device had at least
             * one I/O in flight. Both normalize the ms-based counters by
             * the actual interval length. */
            aqu_sz = (double)weighted_ticks_d / ((double)delay * 1000.0);
            util   = (double)io_ticks_d / ((double)delay * 1000.0) * 100.0;

            printf(
                "%-13s %7.2f %7.2f %8.1f %8.1f %7.2f %7.2f %8.2f %8.2f %7.2f %6.2f\n",
                after[i].name,
                (double)reads_d / (double)delay,
                (double)writes_d / (double)delay,
                (double)sread_d * 512.0 / 1024.0 / (double)delay,
                (double)swrite_d * 512.0 / 1024.0 / (double)delay,
                (double)reads_merged_d / (double)delay,
                (double)writes_merged_d / (double)delay,
                r_await,
                w_await,
                aqu_sz,
                util
            );
        }

        fflush(stdout);

        memcpy(before, after, sizeof(diskstat_t) * (size_t)after_count);
        before_count = after_count;
    }

    return 0;
}


/* ------------------------------------------------------------------ */
/* top                                                                 */
/* ------------------------------------------------------------------ */

#define TOP_MAX_PROCS 512
#define TOP_DISPLAY_LIMIT_DEFAULT 30

typedef struct {
    int pid;
    char cmdline[256];
    unsigned long long cpu_ticks;
    unsigned long long rss_kb;
    double cpu_percent;
} top_proc_t;

/* Reads /proc/<pid>/stat for the process name and utime+stime (in clock
 * ticks). Parses past ")" for the same reason count_proc_states() does -
 * comm can contain spaces or parens, so the state field starts right
 * after the LAST ')', not the first space. */
static int read_proc_stat_ticks(int pid, char *comm, size_t comm_len, unsigned long long *ticks)
{
    char path[64];
    char buf[512];
    FILE *f;
    size_t n;
    char *open_paren;
    char *close_paren;
    char *rest;
    unsigned long long utime, stime;

    *ticks = 0;

    if (comm)
        comm[0] = '\0';

    snprintf(path, sizeof(path), "/proc/%d/stat", pid);

    f = fopen(path, "r");

    if (!f)
        return 1;

    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);

    if (n == 0)
        return 1;

    buf[n] = '\0';

    open_paren = strchr(buf, '(');
    close_paren = strrchr(buf, ')');

    if (!open_paren || !close_paren || close_paren < open_paren)
        return 1;

    if (comm) {
        size_t len = (size_t)(close_paren - open_paren - 1);

        if (len >= comm_len)
            len = comm_len - 1;

        memcpy(comm, open_paren + 1, len);
        comm[len] = '\0';
    }

    /* Fields after "pid (comm) ": state ppid pgrp session tty_nr tpgid
     * flags minflt cminflt majflt cmajflt utime stime ... */
    rest = close_paren + 2;

    if (sscanf(rest, "%*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu",
               &utime, &stime) != 2)
        return 1;

    *ticks = utime + stime;

    return 0;
}

static unsigned long long read_proc_rss_kb(int pid)
{
    char path[64];
    char line[256];
    FILE *f;
    unsigned long long rss = 0;

    snprintf(path, sizeof(path), "/proc/%d/status", pid);

    f = fopen(path, "r");

    if (!f)
        return 0;

    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "VmRSS:", 6) == 0) {
            sscanf(line + 6, "%llu", &rss);
            break;
        }
    }

    fclose(f);

    return rss;
}

static int top_compare_cpu(const void *a, const void *b)
{
    const top_proc_t *pa = a;
    const top_proc_t *pb = b;

    if (pa->cpu_percent > pb->cpu_percent)
        return -1;

    if (pa->cpu_percent < pb->cpu_percent)
        return 1;

    /* Tiebreak on PID ascending - qsort is not stable, so without this,
     * the many processes that are equally idle (0.0% CPU, most of them
     * on a typical system) would reshuffle their relative order between
     * rounds for no reason. */
    return pa->pid - pb->pid;
}

static int top_compare_mem(const void *a, const void *b)
{
    const top_proc_t *pa = a;
    const top_proc_t *pb = b;

    if (pa->rss_kb > pb->rss_kb)
        return -1;

    if (pa->rss_kb < pb->rss_kb)
        return 1;

    return pa->pid - pb->pid;
}

static int top_snapshot(top_proc_t *procs, int max_procs, int want_rss)
{
    DIR *proc;
    struct dirent *entry;
    int count = 0;

    proc = opendir("/proc");

    if (!proc) {
        perror("/proc");
        return -1;
    }

    while (count < max_procs && (entry = readdir(proc)) != NULL) {
        int pid;

        if (!is_number(entry->d_name))
            continue;

        pid = atoi(entry->d_name);

        /* NULL comm - the display name comes from read_cmdline() below
         * (full command line, with the same kernel-thread comm fallback
         * ps already uses), not from /proc/<pid>/stat's own comm field. */
        if (read_proc_stat_ticks(pid, NULL, 0, &procs[count].cpu_ticks) != 0)
            continue;

        read_cmdline(pid, procs[count].cmdline, sizeof(procs[count].cmdline));

        procs[count].pid = pid;
        procs[count].rss_kb = want_rss ? read_proc_rss_kb(pid) : 0;
        procs[count].cpu_percent = 0.0;
        count++;
    }

    closedir(proc);

    return count;
}

static int cmd_top(int argc, char **argv)
{
    static const char usage_msg[] = "Usage: nshbox top [-m] [-l lines] [delay [count]]\n";

    static top_proc_t before[TOP_MAX_PROCS];
    static top_proc_t after[TOP_MAX_PROCS];
    int before_count, after_count;
    int sort_by_mem = 0;
    long display_limit = TOP_DISPLAY_LIMIT_DEFAULT;
    long delay = 1;
    long count = -1; /* default: behave like "top 1" - repeat every second until interrupted */
    long iteration;
    long clk_tck;
    int arg = 1;
    int i, j;

    while (arg < argc && argv[arg][0] == '-' && argv[arg][1]) {
        if (strcmp(argv[arg], "-m") == 0) {
            sort_by_mem = 1;
            arg++;
        } else if (strcmp(argv[arg], "-l") == 0) {
            char *end;

            if (++arg >= argc) {
                fprintf(stderr, "%s", usage_msg);
                return 1;
            }

            errno = 0;
            display_limit = strtol(argv[arg], &end, 10);

            if (errno || *end || display_limit < 1) {
                fprintf(stderr, "%s", usage_msg);
                return 1;
            }

            arg++;
        } else {
            fprintf(stderr, "%s", usage_msg);
            return 1;
        }
    }

    if (arg < argc) {
        char *end;

        errno = 0;
        delay = strtol(argv[arg], &end, 10);

        if (errno || *end || delay < 1) {
            fprintf(stderr, "%s", usage_msg);
            return 1;
        }

        arg++;
        count = -1; /* delay given, no count => repeat until interrupted */
    }

    if (arg < argc) {
        char *end;

        errno = 0;
        count = strtol(argv[arg], &end, 10);

        if (errno || *end || count < 1) {
            fprintf(stderr, "%s", usage_msg);
            return 1;
        }

        arg++;
    }

    if (arg != argc) {
        fprintf(stderr, "%s", usage_msg);
        return 1;
    }

    clk_tck = sysconf(_SC_CLK_TCK);

    if (clk_tck < 1)
        clk_tck = 100;

    before_count = top_snapshot(before, TOP_MAX_PROCS, 0);

    if (before_count < 0)
        return 1;

    for (iteration = 0; count < 0 || iteration < count; iteration++) {
        sleep((unsigned int)delay);

        after_count = top_snapshot(after, TOP_MAX_PROCS, 1);

        if (after_count < 0)
            return 1;

        for (i = 0; i < after_count; i++) {
            unsigned long long delta = 0;

            for (j = 0; j < before_count; j++) {
                if (before[j].pid == after[i].pid) {
                    if (after[i].cpu_ticks >= before[j].cpu_ticks)
                        delta = after[i].cpu_ticks - before[j].cpu_ticks;

                    break;
                }
            }

            after[i].cpu_percent = 100.0 * (double)delta / ((double)clk_tck * (double)delay);
        }

        qsort(after, (size_t)after_count, sizeof(after[0]), sort_by_mem ? top_compare_mem : top_compare_cpu);

        /* Redraw from the top of the screen each round, like the real
         * top - same escape sequence "clear" uses. Reprinted every round
         * (not just once up front) since the clear would otherwise wipe
         * it after the first refresh. */
        fputs("\033[H\033[2J", stdout);

        {
            int shown = (after_count < display_limit) ? after_count : (int)display_limit;

            if (count < 0)
                printf("sort=%s delay=%lds count=until interrupted shown=%d/%d\n\n",
                       sort_by_mem ? "mem" : "cpu", delay, shown, after_count);
            else
                printf("sort=%s delay=%lds count=%ld shown=%d/%d\n\n",
                       sort_by_mem ? "mem" : "cpu", delay, count, shown, after_count);
        }

        printf("%7s %6s %10s  %-10s %s\n", "PID", "CPU%", "RSS(kB)", "TIME", "COMMAND");

        for (i = 0; i < after_count && i < display_limit; i++) {
            char time_str[32];

            format_cpu_time(after[i].cpu_ticks, clk_tck, time_str, sizeof(time_str));

            printf("%7d %6.1f %10llu  %-10s %s\n",
                   after[i].pid, after[i].cpu_percent, after[i].rss_kb, time_str, after[i].cmdline);
        }

        fflush(stdout);

        memcpy(before, after, sizeof(top_proc_t) * (size_t)after_count);
        before_count = after_count;
    }

    return 0;
}


/* ------------------------------------------------------------------ */
/* iotest                                                             */
/* ------------------------------------------------------------------ */

#define IOTEST_BUFFER_SIZE (64 * 1024)

static void iotest_fill_pattern(unsigned char *buf, size_t len, uint32_t *state)
{
    size_t i;

    /* Fast deterministic xorshift32 PRNG, state carried across calls so
     * every round gets different content - not cryptographic, just needs
     * to avoid an all-zero or repeated-block pattern that some flash
     * controllers/filesystems can special-case (compression, dedup),
     * which would inflate the measured throughput. Same seed each run,
     * so results stay reproducible. */
    for (i = 0; i < len; i++) {
        *state ^= *state << 13;
        *state ^= *state >> 17;
        *state ^= *state << 5;
        buf[i] = (unsigned char)(*state & 0xffU);
    }
}

static int parse_iotest_size(const char *s, unsigned long long *out)
{
    char *end;
    unsigned long long value;
    unsigned long long multiplier = 1;

    errno = 0;
    value = strtoull(s, &end, 10);

    if (errno || end == s)
        return 1;

    if (*end != '\0') {
        switch (*end) {
            case 'k': case 'K': multiplier = 1024ULL; break;
            case 'm': case 'M': multiplier = 1024ULL * 1024ULL; break;
            case 'g': case 'G': multiplier = 1024ULL * 1024ULL * 1024ULL; break;
            default: return 1;
        }

        if (end[1] != '\0')
            return 1;
    }

    *out = value * multiplier;

    return 0;
}

/* Refuses to touch anything but a regular file - opens the path, then
 * fstat()s the resulting fd and checks S_ISREG. Checking the fd rather
 * than pattern-matching the path (e.g. rejecting "/dev/mtd*" strings)
 * closes the symlink loophole: whatever the path looks like, this is
 * what the kernel actually opened. */
static int iotest_open_regular(const char *path, int flags, mode_t mode, int *fd_out)
{
    int fd;
    struct stat st;

    fd = open(path, flags, mode);

    if (fd < 0) {
        perror(path);
        return 1;
    }

    if (fstat(fd, &st) != 0) {
        perror(path);
        close(fd);
        return 1;
    }

    if (!S_ISREG(st.st_mode)) {
        fprintf(
            stderr,
            "iotest: %s: refusing - not a regular file (iotest only ever tests regular files, never device nodes)\n",
            path
        );
        close(fd);
        return 1;
    }

    *fd_out = fd;

    return 0;
}

/* Refuses to write if it would leave the filesystem too full - this
 * device has very little storage. Requires at least 10% of the
 * filesystem's *current* free space (or 1 MiB, whichever is larger) to
 * remain free after the write, so the check scales with however much
 * space actually exists rather than a single hardcoded number. */
static int iotest_check_free_space(const char *path, unsigned long long size)
{
    struct statvfs vfs;
    char dir[PATH_MAX];
    char *slash;
    unsigned long long available;
    unsigned long long margin;

    if (strlen(path) >= sizeof(dir)) {
        fprintf(stderr, "iotest: path too long: %s\n", path);
        return 1;
    }

    strcpy(dir, path);
    slash = strrchr(dir, '/');

    if (slash == dir)
        dir[1] = '\0';
    else if (slash)
        *slash = '\0';
    else
        strcpy(dir, ".");

    if (statvfs(dir, &vfs) != 0) {
        perror(dir);
        return 1;
    }

    available = (unsigned long long)vfs.f_bavail * (unsigned long long)vfs.f_frsize;
    margin = available / 10;

    if (margin < 1024ULL * 1024ULL)
        margin = 1024ULL * 1024ULL;

    if (size + margin > available) {
        fprintf(
            stderr,
            "iotest: refusing to write %llu bytes - only %llu bytes available on %s "
            "(keeping a %llu byte safety margin so this write can't fill the disk)\n",
            size, available, dir, margin
        );
        return 1;
    }

    return 0;
}

typedef enum {
    IOTEST_STOP_SIZE,   /* stop once this many total bytes are written */
    IOTEST_STOP_TIME,   /* stop once this many seconds have elapsed */
    IOTEST_STOP_ROUNDS  /* stop after this many buffer-sized writes */
} iotest_stop_t;

static int cmd_iotest_write(const char *path, iotest_stop_t stop_mode,
                            unsigned long long size_limit, double time_limit,
                            unsigned long long round_limit, unsigned long long cap)
{
    int fd;
    unsigned char buf[IOTEST_BUFFER_SIZE];
    uint32_t prng_state = 0x12345678U;
    unsigned long long total_written = 0;
    unsigned long long rounds_done = 0;
    unsigned long long file_offset = 0;
    unsigned long long footprint;
    struct timespec start, end, now;
    double elapsed, mib, safe_elapsed;

    /* SIZE mode has its own inherent bound (size_limit), so a cap is
     * optional there and the free-space check can fall back to it. TIME
     * and ROUNDS mode have no such bound on their own - how much gets
     * written depends on device speed - so the caller (cmd_iotest)
     * requires a cap for those, and it alone determines the footprint. */
    if (stop_mode == IOTEST_STOP_SIZE)
        footprint = (cap > 0 && cap < size_limit) ? cap : size_limit;
    else
        footprint = cap;

    if (iotest_check_free_space(path, footprint) != 0)
        return 1;

    if (iotest_open_regular(path, O_WRONLY | O_CREAT | O_TRUNC, 0644, &fd) != 0)
        return 1;

    clock_gettime(CLOCK_MONOTONIC, &start);

    for (;;) {
        size_t chunk;
        ssize_t n;

        if (stop_mode == IOTEST_STOP_SIZE) {
            unsigned long long remaining = size_limit - total_written;

            if (remaining == 0)
                break;

            chunk = (remaining < sizeof(buf)) ? (size_t)remaining : sizeof(buf);
        } else if (stop_mode == IOTEST_STOP_ROUNDS) {
            if (rounds_done >= round_limit)
                break;

            chunk = sizeof(buf);
        } else {
            /* IOTEST_STOP_TIME - checked before each round, so the
             * actual elapsed time reported at the end can run a little
             * past time_limit (by up to one round's write time); this
             * never interrupts a write already in progress. */
            clock_gettime(CLOCK_MONOTONIC, &now);
            elapsed = (double)(now.tv_sec - start.tv_sec) + (double)(now.tv_nsec - start.tv_nsec) / 1e9;

            if (elapsed >= time_limit)
                break;

            chunk = sizeof(buf);
        }

        if (cap > 0) {
            unsigned long long room = cap - file_offset;

            if ((unsigned long long)chunk > room)
                chunk = (size_t)room;
        }

        iotest_fill_pattern(buf, chunk, &prng_state);

        n = write(fd, buf, chunk);

        if (n < 0) {
            if (errno == EINTR)
                continue;

            perror(path);
            close(fd);
            return 1;
        }

        if (n == 0) {
            fprintf(stderr, "iotest: %s: write returned 0 (disk full?)\n", path);
            close(fd);
            return 1;
        }

        total_written += (unsigned long long)n;
        file_offset += (unsigned long long)n;
        rounds_done++;

        /* Wrap back to the start of the file once the cap is reached,
         * rather than letting the file keep growing - the whole point
         * of `cap` is to bound the actual disk footprint. */
        if (cap > 0 && file_offset >= cap) {
            if (lseek(fd, 0, SEEK_SET) < 0) {
                perror(path);
                close(fd);
                return 1;
            }

            file_offset = 0;
        }
    }

    if (fsync(fd) != 0) {
        perror(path);
        close(fd);
        return 1;
    }

    clock_gettime(CLOCK_MONOTONIC, &end);

    if (close(fd) != 0) {
        perror(path);
        return 1;
    }

    elapsed = (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) / 1e9;
    safe_elapsed = (elapsed > 0.0001) ? elapsed : 0.0001;
    mib = (double)total_written / (1024.0 * 1024.0);

    printf("WRITE  %.1f MiB in %.2f s  = %.1f MiB/s (%llu rounds)\n", mib, elapsed, mib / safe_elapsed, rounds_done);

    return 0;
}

static int cmd_iotest_read(const char *path)
{
    int fd;
    unsigned char buf[IOTEST_BUFFER_SIZE];
    unsigned long long total = 0;
    struct timespec start, end;
    double elapsed, mib, safe_elapsed;
    ssize_t n;

    if (iotest_open_regular(path, O_RDONLY, 0, &fd) != 0)
        return 1;

    /* Best-effort: ask the kernel to drop this file's page cache so we
     * measure real device throughput, not a second read served from
     * RAM. Advisory only - if the kernel/filesystem ignores it, the
     * read is still correctly timed, just possibly cache-assisted. */
    posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);

    clock_gettime(CLOCK_MONOTONIC, &start);

    for (;;) {
        n = read(fd, buf, sizeof(buf));

        if (n < 0) {
            if (errno == EINTR)
                continue;

            perror(path);
            close(fd);
            return 1;
        }

        if (n == 0)
            break;

        total += (unsigned long long)n;
    }

    clock_gettime(CLOCK_MONOTONIC, &end);

    close(fd);

    elapsed = (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) / 1e9;
    safe_elapsed = (elapsed > 0.0001) ? elapsed : 0.0001;
    mib = (double)total / (1024.0 * 1024.0);

    printf("READ   %.1f MiB in %.2f s  = %.1f MiB/s\n", mib, elapsed, mib / safe_elapsed);

    return 0;
}

static int cmd_iotest(int argc, char **argv)
{
    static const char usage_msg[] =
        "Usage: nshbox iotest -w <file> <size>[K|M|G] [cap[K|M|G]]\n"
        "       nshbox iotest -w <file> -t <seconds> <cap>[K|M|G]\n"
        "       nshbox iotest -w <file> -n <rounds> <cap>[K|M|G]\n"
        "         <size>[K|M|G]  total bytes to write (e.g. 16M = 16 MiB, plain number = bytes)\n"
        "         -t <seconds>   write until this many seconds have elapsed\n"
        "         -n <rounds>    write exactly this many 64 KiB rounds\n"
        "         cap[K|M|G]     cap the file at this size and wrap (seek back to the start)\n"
        "                        instead of growing past it. Optional with a plain <size> (which\n"
        "                        is already its own bound); REQUIRED with -t/-n, since neither\n"
        "                        has any other limit on how large the file could grow\n"
        "       nshbox iotest -r <file>\n";

    if (argc >= 4 && strcmp(argv[1], "-w") == 0 && strcmp(argv[3], "-t") == 0) {
        double seconds;
        unsigned long long cap;
        char *end;

        if (argc != 6) {
            fprintf(stderr, "%s", usage_msg);
            return 1;
        }

        errno = 0;
        seconds = strtod(argv[4], &end);

        if (errno || *end || seconds <= 0.0) {
            fprintf(stderr, "iotest: invalid seconds: %s\n", argv[4]);
            return 1;
        }

        if (parse_iotest_size(argv[5], &cap) != 0 || cap == 0) {
            fprintf(stderr, "iotest: invalid cap: %s\n", argv[5]);
            return 1;
        }

        return cmd_iotest_write(argv[2], IOTEST_STOP_TIME, 0, seconds, 0, cap);
    }

    if (argc >= 4 && strcmp(argv[1], "-w") == 0 && strcmp(argv[3], "-n") == 0) {
        unsigned long long rounds;
        unsigned long long cap;
        char *end;

        if (argc != 6) {
            fprintf(stderr, "%s", usage_msg);
            return 1;
        }

        errno = 0;
        rounds = strtoull(argv[4], &end, 10);

        if (errno || *end || rounds == 0) {
            fprintf(stderr, "iotest: invalid round count: %s\n", argv[4]);
            return 1;
        }

        if (parse_iotest_size(argv[5], &cap) != 0 || cap == 0) {
            fprintf(stderr, "iotest: invalid cap: %s\n", argv[5]);
            return 1;
        }

        return cmd_iotest_write(argv[2], IOTEST_STOP_ROUNDS, 0, 0.0, rounds, cap);
    }

    if ((argc == 4 || argc == 5) && strcmp(argv[1], "-w") == 0) {
        unsigned long long size;
        unsigned long long cap = 0;

        if (parse_iotest_size(argv[3], &size) != 0 || size == 0) {
            fprintf(stderr, "iotest: invalid size: %s\n", argv[3]);
            return 1;
        }

        if (argc == 5 && (parse_iotest_size(argv[4], &cap) != 0 || cap == 0)) {
            fprintf(stderr, "iotest: invalid cap: %s\n", argv[4]);
            return 1;
        }

        return cmd_iotest_write(argv[2], IOTEST_STOP_SIZE, size, 0.0, 0, cap);
    }

    if (argc == 3 && strcmp(argv[1], "-r") == 0)
        return cmd_iotest_read(argv[2]);

    fprintf(stderr, "%s", usage_msg);
    return 1;
}


/* ------------------------------------------------------------------ */
/* readlink                                                           */
/* ------------------------------------------------------------------ */

static int cmd_readlink(int argc, char **argv)
{
    char buf[PATH_MAX];
    ssize_t len;

    if (argc == 3 && strcmp(argv[1], "-f") == 0) {
        char *resolved = realpath(argv[2], buf);

        if (!resolved) {
            perror(argv[2]);
            return 1;
        }

        printf("%s\n", resolved);
        return 0;
    }

    if (argc != 2) {
        fprintf(stderr, "Usage: nshbox readlink [-f] <path>\n");
        return 1;
    }

    len = readlink(argv[1], buf, sizeof(buf) - 1);

    if (len < 0) {
        perror(argv[1]);
        return 1;
    }

    buf[len] = '\0';
    printf("%s\n", buf);
    return 0;
}


/* ------------------------------------------------------------------ */
/* realpath                                                           */
/* ------------------------------------------------------------------ */

static int cmd_realpath(int argc, char **argv)
{
    int i;
    int rc = 0;

    if (argc < 2) {
        fprintf(stderr, "Usage: nshbox realpath <path> [...]\n");
        return 1;
    }

    for (i = 1; i < argc; i++) {
        char resolved[PATH_MAX];

        if (!realpath(argv[i], resolved)) {
            perror(argv[i]);
            rc = 1;
            continue;
        }

        printf("%s\n", resolved);
    }

    return rc;
}


/* ------------------------------------------------------------------ */
/* dirname                                                             */
/* ------------------------------------------------------------------ */

/* Self-contained, not libgen.h's dirname(3): that function is allowed to
 * modify its input buffer in place and may return a pointer into static
 * storage depending on the C library, both of which are exactly the kind
 * of libc-behavior-dependent surprise this project has already hit once
 * with dynamic linking (see nshbox/README.md) - a small, purely-string
 * implementation with well-defined behavior for every case this project
 * actually needs (added after a real device failure: on-device scripts
 * invoked via a bare "adb shell" have no "dirname" at all - see
 * docs/device_layout.md's "PATH" section) is simpler to reason about than
 * depending on whichever libc this binary happens to be linked against.
 * Matches GNU coreutils' dirname(1) for every case that matters here:
 * strips trailing slashes, then the last path component; a path with no
 * slash gives ".", and a path that is (or reduces to) just slashes gives
 * "/".
 */
static void dirname_one(const char *path, char *out, size_t out_size)
{
    size_t len = strlen(path);
    size_t end = len;
    size_t i;

    while (end > 1 && path[end - 1] == '/')
        end--;

    if (end == 1 && path[0] == '/') {
        snprintf(out, out_size, "/");
        return;
    }

    i = end;
    while (i > 0 && path[i - 1] != '/')
        i--;

    if (i == 0) {
        snprintf(out, out_size, ".");
        return;
    }

    while (i > 1 && path[i - 1] == '/')
        i--;

    if (i == 1 && path[0] == '/') {
        snprintf(out, out_size, "/");
        return;
    }

    if (i >= out_size)
        i = out_size - 1;

    memcpy(out, path, i);
    out[i] = '\0';
}

static int cmd_dirname(int argc, char **argv)
{
    int i;

    if (argc < 2) {
        fprintf(stderr, "Usage: nshbox dirname <path> [...]\n");
        return 1;
    }

    for (i = 1; i < argc; i++) {
        char out[PATH_MAX];

        dirname_one(argv[i], out, sizeof(out));
        printf("%s\n", out);
    }

    return 0;
}


/* ------------------------------------------------------------------ */
/* info                                                               */
/* ------------------------------------------------------------------ */

/* Reads /proc/cpuinfo once: the (first) "model name" and "Features"
 * values (identical across cores on every SMP system seen so far, so
 * one copy is enough), the "Hardware" line (printed once, after all
 * per-core blocks), and a count of "processor" lines for the core
 * count. Deliberately proc-only for now - no device-tree clock-frequency
 * lookup, so there is no CPU clock field: this device's /proc/cpuinfo
 * has no "cpu MHz" either, so that field would be empty here anyway. */
static void read_cpuinfo(char *model, size_t model_len,
                         char *features, size_t features_len,
                         char *hardware, size_t hardware_len,
                         unsigned long *cores)
{
    FILE *f;
    char line[512];

    model[0] = '\0';
    features[0] = '\0';
    hardware[0] = '\0';
    *cores = 0;

    f = fopen("/proc/cpuinfo", "r");

    if (!f)
        return;

    while (fgets(line, sizeof(line), f)) {
        char *colon;
        char *value;
        size_t len;

        if (strncmp(line, "processor", 9) == 0)
            (*cores)++;

        colon = strchr(line, ':');

        if (!colon)
            continue;

        value = colon + 1;

        while (*value == ' ' || *value == '\t')
            value++;

        len = strlen(value);

        while (len > 0 && (value[len - 1] == '\n' || value[len - 1] == '\r'))
            value[--len] = '\0';

        if (model[0] == '\0' && strncmp(line, "model name", 10) == 0) {
            strncpy(model, value, model_len - 1);
            model[model_len - 1] = '\0';
        } else if (features[0] == '\0' && strncmp(line, "Features", 8) == 0) {
            strncpy(features, value, features_len - 1);
            features[features_len - 1] = '\0';
        } else if (hardware[0] == '\0' && strncmp(line, "Hardware", 8) == 0) {
            strncpy(hardware, value, hardware_len - 1);
            hardware[hardware_len - 1] = '\0';
        }
    }

    fclose(f);
}

/* Formats seconds as "1d 4h 59m" - omitting the leading unit(s) once
 * they're zero (no "0d" prefix once uptime drops under a day, etc.), but
 * always showing minutes even at "0m" for a very fresh boot. */
static void format_uptime(double seconds, char *buf, size_t buflen)
{
    long total_minutes = (long)(seconds / 60.0);
    long days = total_minutes / (60 * 24);
    long hours = (total_minutes / 60) % 24;
    long minutes = total_minutes % 60;

    if (days > 0)
        snprintf(buf, buflen, "%ldd %ldh %ldm", days, hours, minutes);
    else if (hours > 0)
        snprintf(buf, buflen, "%ldh %ldm", hours, minutes);
    else
        snprintf(buf, buflen, "%ldm", minutes);
}

/* Formats seconds GNU uptime's own way ("2 days,  3:14" / " 3:14" /
 * "5 min") - deliberately different from format_uptime() above, which
 * sysinfo uses instead ("1d 4h 59m") - two different, independently
 * reasonable conventions for two different commands, not an
 * inconsistency. Approximate, not byte-for-byte diffed against real
 * uptime output the way the checksum commands were against real
 * coreutils - close enough for a human glance, not a scripted parser
 * target. */
static void format_uptime_standard(double seconds, char *buf, size_t buflen)
{
    long total_minutes = (long)(seconds / 60.0);
    long days = total_minutes / (60 * 24);
    long hours = (total_minutes / 60) % 24;
    long minutes = total_minutes % 60;

    if (days > 0)
        snprintf(buf, buflen, "%ld day%s, %2ld:%02ld", days, days == 1 ? "" : "s", hours, minutes);
    else if (hours > 0)
        snprintf(buf, buflen, "%ld:%02ld", hours, minutes);
    else
        snprintf(buf, buflen, "%ld min", minutes);
}

/* No logged-in-user count, unlike real uptime - this device has no
 * working utmp to read one from (an Android-derived environment, not a
 * traditional multi-user Linux login setup), and fabricating a number
 * would be worse than just leaving it out. Load average comes from
 * /proc/loadavg, which - unlike utmp - is a genuine, meaningful kernel
 * facility on any Linux system regardless of login sessions. */
static int cmd_uptime(int argc, char **argv)
{
    int json = 0;
    int i;
    FILE *f;
    double uptime_seconds = 0.0;
    double load1 = 0.0, load5 = 0.0, load15 = 0.0;
    int have_uptime = 0, have_load = 0;
    time_t now;
    struct tm *tm_now;
    char time_str[16] = "??:??:??";
    char up_str[64] = "unknown";

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) {
            json = 1;
        } else {
            fprintf(stderr, "Usage: nshbox uptime [--json]\n");
            return 2;
        }
    }

    f = fopen("/proc/uptime", "r");

    if (f) {
        if (fscanf(f, "%lf", &uptime_seconds) == 1)
            have_uptime = 1;
        fclose(f);
    }

    f = fopen("/proc/loadavg", "r");

    if (f) {
        if (fscanf(f, "%lf %lf %lf", &load1, &load5, &load15) == 3)
            have_load = 1;
        fclose(f);
    }

    now = time(NULL);
    tm_now = localtime(&now);

    if (tm_now)
        strftime(time_str, sizeof(time_str), "%H:%M:%S", tm_now);

    if (have_uptime)
        format_uptime_standard(uptime_seconds, up_str, sizeof(up_str));

    if (json) {
        printf("{\"time\":\"%s\",\"uptime_seconds\":%.0f,\"load_average\":",
               time_str, uptime_seconds);

        if (have_load)
            printf("{\"1min\":%.2f,\"5min\":%.2f,\"15min\":%.2f}", load1, load5, load15);
        else
            printf("null");

        printf("}\n");
    } else {
        printf(" %s up %s", time_str, up_str);

        if (have_load)
            printf(",  load average: %.2f, %.2f, %.2f", load1, load5, load15);

        printf("\n");
    }

    return 0;
}

/* json_print_string() itself has no missing-value handling of its own
 * (every existing caller already has a real string in hand) - sysinfo
 * is the first --json command whose string fields are individually
 * optional (uname()/proc/cpuinfo entries can legitimately be missing on
 * a given platform, same as their plain-text "if (x[0])" guards below),
 * so this wraps it rather than repeating the same check at every one of
 * sysinfo's own call sites. Falls back to "" rather than null - every
 * key stays the same JSON type (string) whether or not the underlying
 * data was found, which is simpler for a consumer to parse than having
 * to handle a string-or-null union on every one of these fields.
 * sysinfo's two numeric fields that can also be missing (cpu_cores,
 * uptime_seconds) fall back to "" too, for the same "no null anywhere
 * in this output" consistency, rather than 0 - which would look like a
 * real, if implausible, value instead of an obvious placeholder. */
static void json_print_string_or_empty(const char *s)
{
    json_print_string(s && s[0] ? s : "");
}

static int cmd_sysinfo(int argc, char **argv)
{
    struct utsname u;
    int have_uname;
    FILE *f;
    char model[128];
    char features[256];
    char hardware[128];
    unsigned long cores;
    unsigned long long mem_total, mem_available;
    double uptime_seconds = 0.0;
    int have_uptime = 0;
    int json = 0;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) {
            json = 1;
        } else {
            fprintf(stderr, "Usage: nshbox sysinfo [--json]\n");
            return 2;
        }
    }

    have_uname = (uname(&u) == 0);

    read_cpuinfo(model, sizeof(model), features, sizeof(features), hardware, sizeof(hardware), &cores);
    read_meminfo_kb("MemTotal", &mem_total);
    read_meminfo_kb("MemAvailable", &mem_available);

    f = fopen("/proc/uptime", "r");

    if (f) {
        have_uptime = (fscanf(f, "%lf", &uptime_seconds) == 1);
        fclose(f);
    }

    if (json) {
        printf("{\"system\":");
        json_print_string_or_empty(have_uname ? u.sysname : NULL);
        printf(",\"node\":");
        json_print_string_or_empty(have_uname ? u.nodename : NULL);
        printf(",\"kernel\":");
        json_print_string_or_empty(have_uname ? u.release : NULL);
        printf(",\"machine\":");
        json_print_string_or_empty(have_uname ? u.machine : NULL);
        printf(",\"hardware\":");
        json_print_string_or_empty(hardware);
        printf(",\"cpu\":");
        json_print_string_or_empty(model);
        printf(",\"cpu_cores\":");
        if (cores > 0)
            printf("%lu", cores);
        else
            printf("\"\"");
        printf(",\"cpu_features\":");
        json_print_string_or_empty(features);
        printf(",\"memory_kb\":%llu,\"available_kb\":%llu,\"uptime_seconds\":",
               mem_total, mem_available);
        if (have_uptime)
            printf("%.0f", uptime_seconds);
        else
            printf("\"\"");
        printf("}\n");
        return 0;
    }

    printf("\nnshbox %s\n\n", NSHBOX_VERSION);

    if (have_uname) {
        printf("%-15s%s\n", "System:", u.sysname);
        printf("%-15s%s\n", "Node:", u.nodename);
        printf("%-15s%s\n", "Kernel:", u.release);
        printf("%-15s%s\n", "Machine:", u.machine);
    }

    if (hardware[0])
        printf("%-15s%s\n", "Hardware:", hardware);

    printf("\n");

    if (model[0])
        printf("%-15s%s\n", "CPU:", model);

    if (cores > 0)
        printf("%-15s%lu\n", "CPU cores:", cores);

    if (features[0])
        printf("%-15s%s\n", "CPU features:", features);

    printf("\n");

    printf("%-15s%llu kB\n", "Memory:", mem_total);
    printf("%-15s%llu kB\n", "Available:", mem_available);

    if (have_uptime) {
        char uptime_str[32];

        format_uptime(uptime_seconds, uptime_str, sizeof(uptime_str));
        printf("%-15s%s\n", "Uptime:", uptime_str);
    }

    printf("\n");

    return 0;
}


/* ------------------------------------------------------------------ */
/* clear                                                              */
/* ------------------------------------------------------------------ */

static int cmd_clear(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    fputs("\033[H\033[2J", stdout);
    fflush(stdout);
    return 0;
}

/* Added after a real, confirmed gap (2026-09-13): sshd.sh's own PID-file
   wait loop calls plain "sleep 1" and hit "sleep: not found" on-device -
   the same class of missing-command issue already found for sha256sum/
   readlink (see verify_installation.sh) - this device's default shell
   environment just does not have it. Minimal, single-argument,
   fractional-seconds support via nanosleep() - not attempting GNU sleep's
   multiple-argument summing or "5m"/"2h" unit suffixes, since nothing in
   this project needs them. */
static int cmd_sleep(int argc, char **argv)
{
    double seconds;
    char *endptr;
    struct timespec ts;

    if (argc != 2) {
        fprintf(stderr, "Usage: nshbox sleep SECONDS\n");
        return 2;
    }

    seconds = strtod(argv[1], &endptr);

    if (endptr == argv[1] || *endptr != '\0' || seconds < 0) {
        fprintf(stderr, "sleep: invalid time interval '%s'\n", argv[1]);
        return 1;
    }

    ts.tv_sec = (time_t)seconds;
    ts.tv_nsec = (long)((seconds - (double)ts.tv_sec) * 1000000000.0);

    if (nanosleep(&ts, NULL) != 0 && errno != EINTR) {
        fprintf(stderr, "sleep: %s\n", strerror(errno));
        return 1;
    }

    return 0;
}


/* ------------------------------------------------------------------ */
/* which                                                              */
/* ------------------------------------------------------------------ */

static int cmd_which(int argc, char **argv)
{
    const char *path;
    int rc = 0;
    int i;

    if (argc < 2) {
        fprintf(stderr, "Usage: nshbox which <command> [...]\n");
        return 1;
    }

    path = getenv("PATH");
    if (!path)
        path = "/bin:/usr/bin:/sbin:/usr/sbin";

    for (i = 1; i < argc; i++) {
        char *copy;
        char *save = NULL;
        char *dir;
        int found = 0;

        if (strchr(argv[i], '/')) {
            if (access(argv[i], X_OK) == 0) {
                puts(argv[i]);
                continue;
            }
            rc = 1;
            continue;
        }

        copy = strdup(path);
        if (!copy) {
            perror("strdup");
            return 1;
        }

        for (dir = strtok_r(copy, ":", &save); dir; dir = strtok_r(NULL, ":", &save)) {
            char candidate[PATH_MAX];
            struct stat st;

            if (*dir == '\0')
                dir = ".";

            if (snprintf(candidate, sizeof(candidate), "%s/%s", dir, argv[i]) >= (int)sizeof(candidate))
                continue;

            if (stat(candidate, &st) == 0 && !S_ISDIR(st.st_mode) && access(candidate, X_OK) == 0) {
                puts(candidate);
                found = 1;
                break;
            }
        }

        free(copy);
        if (!found)
            rc = 1;
    }

    return rc;
}


/* ------------------------------------------------------------------ */
/* strings                                                            */
/* ------------------------------------------------------------------ */

static int strings_stream(FILE *f, size_t min_len)
{
    char *buf = NULL;
    size_t len = 0;
    size_t cap = 0;
    int c;

    while ((c = fgetc(f)) != EOF) {
        if (isprint((unsigned char)c) || c == '\t') {
            if (len + 1 >= cap) {
                size_t new_cap = cap ? cap * 2 : 128;
                char *tmp = realloc(buf, new_cap);
                if (!tmp) {
                    free(buf);
                    perror("realloc");
                    return 1;
                }
                buf = tmp;
                cap = new_cap;
            }
            buf[len++] = (char)c;
        } else {
            if (len >= min_len) {
                buf[len] = '\0';
                puts(buf);
            }
            len = 0;
        }
    }

    if (len >= min_len) {
        buf[len] = '\0';
        puts(buf);
    }

    free(buf);
    return ferror(f) ? 1 : 0;
}

static int cmd_strings(int argc, char **argv)
{
    size_t min_len = 4;
    int arg = 1;
    int rc = 0;

    if (arg < argc && strcmp(argv[arg], "-n") == 0) {
        char *end;
        unsigned long n;

        if (++arg >= argc) {
            fprintf(stderr, "Usage: nshbox strings [-n min] [file ...]\n");
            return 1;
        }

        errno = 0;
        n = strtoul(argv[arg++], &end, 10);
        if (errno || *end || n == 0) {
            fprintf(stderr, "strings: invalid minimum length\n");
            return 1;
        }
        min_len = (size_t)n;
    }

    if (arg == argc)
        return strings_stream(stdin, min_len);

    for (; arg < argc; arg++) {
        FILE *f = fopen(argv[arg], "rb");
        if (!f) {
            perror(argv[arg]);
            rc = 1;
            continue;
        }
        if (strings_stream(f, min_len) != 0)
            rc = 1;
        fclose(f);
    }

    return rc;
}


/* ------------------------------------------------------------------ */
/* hexdump                                                            */
/* ------------------------------------------------------------------ */

static int hexdump_stream(FILE *f)
{
    unsigned char buf[16];
    unsigned long long offset = 0;
    size_t n;

    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        size_t i;

        printf("%08llx  ", offset);
        for (i = 0; i < 16; i++) {
            if (i < n)
                printf("%02x ", buf[i]);
            else
                fputs("   ", stdout);
            if (i == 7)
                putchar(' ');
        }

        fputs(" |", stdout);
        for (i = 0; i < n; i++)
            putchar(isprint(buf[i]) ? buf[i] : '.');
        for (; i < 16; i++)
            putchar(' ');
        puts("|");

        offset += n;
    }

    printf("%08llx\n", offset);
    return ferror(f) ? 1 : 0;
}

static int cmd_hexdump(int argc, char **argv)
{
    FILE *f;
    int rc;

    if (argc > 2) {
        fprintf(stderr, "Usage: nshbox hexdump [file]\n");
        return 1;
    }

    if (argc == 1)
        return hexdump_stream(stdin);

    f = fopen(argv[1], "rb");
    if (!f) {
        perror(argv[1]);
        return 1;
    }
    rc = hexdump_stream(f);
    fclose(f);
    return rc;
}


/* ------------------------------------------------------------------ */
/* file                                                               */
/* ------------------------------------------------------------------ */

#define FILE_PREFIX_SIZE 4096

/* EI_DATA-aware field readers - the ELF header is read byte-by-byte
 * rather than cast to an Elf32_Ehdr or Elf64_Ehdr pointer, so this works
 * correctly for both a foreign-endian ELF file and a misaligned buffer,
 * neither of which a direct struct cast can be trusted with. */
static uint16_t file_u16(const unsigned char *p, int little_endian)
{
    return little_endian
        ? (uint16_t)((unsigned int)p[0] | ((unsigned int)p[1] << 8))
        : (uint16_t)(((unsigned int)p[0] << 8) | (unsigned int)p[1]);
}

static uint32_t file_u32(const unsigned char *p, int little_endian)
{
    if (little_endian) {
        return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
               ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    }

    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t file_u64(const unsigned char *p, int little_endian)
{
    if (little_endian)
        return (uint64_t)file_u32(p, 1) | ((uint64_t)file_u32(p + 4, 1) << 32);

    return ((uint64_t)file_u32(p, 0) << 32) | (uint64_t)file_u32(p + 4, 0);
}

static const char *elf_machine_name(unsigned int machine)
{
    switch (machine) {
        case 3:   return "Intel 80386";
        case 8:   return "MIPS";
        case 40:  return "ARM";
        case 62:  return "x86-64";
        case 183: return "ARM aarch64";
        default:  return "unknown architecture";
    }
}

/* Walks the program header table looking for PT_INTERP (=> dynamically
 * linked; also captures the interpreter path) and PT_DYNAMIC. Every
 * offset is checked against the actual file size before use - a
 * corrupt/truncated ELF file must never cause an out-of-bounds pread(). */
static void elf_walk_program_headers(int fd, int is64, int little_endian,
                                     uint64_t phoff, unsigned int phnum, unsigned int phentsize,
                                     off_t file_size, int *has_interp, char *interp, size_t interp_len,
                                     int *has_dynamic)
{
    unsigned int i;

    *has_interp = 0;
    *has_dynamic = 0;

    if (phentsize == 0 || phoff > (uint64_t)file_size)
        return;

    for (i = 0; i < phnum; i++) {
        unsigned char buf[64]; /* Elf32_Phdr=32B, Elf64_Phdr=56B */
        uint64_t entry_off = phoff + (uint64_t)i * phentsize;
        uint32_t p_type;
        uint64_t p_offset, p_filesz;
        ssize_t n;
        size_t want;

        if (entry_off + phentsize > (uint64_t)file_size)
            break;

        want = phentsize < sizeof(buf) ? phentsize : sizeof(buf);
        n = pread(fd, buf, want, (off_t)entry_off);

        if (n < (is64 ? 40 : 20))
            break;

        p_type = file_u32(buf, little_endian);

        if (is64) {
            p_offset = file_u64(buf + 8, little_endian);
            p_filesz = file_u64(buf + 32, little_endian);
        } else {
            p_offset = file_u32(buf + 4, little_endian);
            p_filesz = file_u32(buf + 16, little_endian);
        }

        if (p_type == 3 /* PT_INTERP */) {
            *has_interp = 1;

            if (p_filesz > 0 && p_filesz < interp_len && p_offset + p_filesz <= (uint64_t)file_size) {
                ssize_t rn = pread(fd, interp, (size_t)p_filesz, (off_t)p_offset);

                if (rn > 0) {
                    size_t len = (size_t)rn;

                    if (len >= interp_len)
                        len = interp_len - 1;

                    interp[len] = '\0';
                } else {
                    interp[0] = '\0';
                }
            }
        } else if (p_type == 2 /* PT_DYNAMIC */) {
            *has_dynamic = 1;
        }
    }
}

/* Walks the section header table looking for SHT_SYMTAB. Returns 1 if
 * found (not stripped), 0 if a section table exists but has no symbol
 * table (stripped), -1 if there is no usable section table at all. */
static int elf_has_symtab(int fd, int little_endian, uint64_t shoff, unsigned int shnum,
                          unsigned int shentsize, off_t file_size)
{
    unsigned int i;

    if (shentsize == 0 || shoff > (uint64_t)file_size)
        return -1;

    for (i = 0; i < shnum; i++) {
        unsigned char buf[8];
        uint64_t entry_off = shoff + (uint64_t)i * shentsize;
        ssize_t n;

        if (entry_off + shentsize > (uint64_t)file_size)
            break;

        n = pread(fd, buf, sizeof(buf), (off_t)entry_off);

        if (n < 8)
            break;

        /* sh_type sits at the same offset (4) in both Elf32_Shdr and
         * Elf64_Shdr, so no is64 branch is needed here. */
        if (file_u32(buf + 4, little_endian) == 2 /* SHT_SYMTAB */)
            return 1;
    }

    return 0;
}

#define EF_ARM_EABIMASK       0xff000000U
#define EF_ARM_ABI_FLOAT_SOFT 0x00000200U
#define EF_ARM_ABI_FLOAT_HARD 0x00000400U

/* Returns 1 and fills desc on a recognizable ELF header, 0 if prefix is
 * too short to be one (caller falls through to other detection). */
static int describe_elf(int fd, const unsigned char *prefix, size_t prefix_len, off_t file_size,
                        char *desc, size_t desc_len)
{
    int is64, little_endian;
    unsigned int e_type, e_machine, e_flags;
    unsigned int e_phnum, e_phentsize, e_shnum, e_shentsize;
    uint64_t e_phoff, e_shoff;
    int has_interp, has_dynamic;
    char interp[192];
    int symtab;
    size_t pos = 0;

    is64 = (prefix[4] == 2);
    little_endian = (prefix[5] == 1);

    if (is64) {
        if (prefix_len < 64)
            return 0;

        e_type = file_u16(prefix + 16, little_endian);
        e_machine = file_u16(prefix + 18, little_endian);
        e_phoff = file_u64(prefix + 32, little_endian);
        e_shoff = file_u64(prefix + 40, little_endian);
        e_flags = file_u32(prefix + 48, little_endian);
        e_phentsize = file_u16(prefix + 54, little_endian);
        e_phnum = file_u16(prefix + 56, little_endian);
        e_shentsize = file_u16(prefix + 58, little_endian);
        e_shnum = file_u16(prefix + 60, little_endian);
    } else {
        if (prefix_len < 52)
            return 0;

        e_type = file_u16(prefix + 16, little_endian);
        e_machine = file_u16(prefix + 18, little_endian);
        e_phoff = file_u32(prefix + 28, little_endian);
        e_shoff = file_u32(prefix + 32, little_endian);
        e_flags = file_u32(prefix + 36, little_endian);
        e_phentsize = file_u16(prefix + 42, little_endian);
        e_phnum = file_u16(prefix + 44, little_endian);
        e_shentsize = file_u16(prefix + 46, little_endian);
        e_shnum = file_u16(prefix + 48, little_endian);
    }

    pos += (size_t)snprintf(desc + pos, desc_len - pos, "ELF %s %s",
                            is64 ? "64-bit" : "32-bit", little_endian ? "LSB" : "MSB");

    switch (e_type) {
        case 1: pos += (size_t)snprintf(desc + pos, desc_len - pos, " relocatable"); break;
        case 2: pos += (size_t)snprintf(desc + pos, desc_len - pos, " executable"); break;
        case 3: pos += (size_t)snprintf(desc + pos, desc_len - pos, " shared object"); break;
        case 4: pos += (size_t)snprintf(desc + pos, desc_len - pos, " core file"); break;
        default: pos += (size_t)snprintf(desc + pos, desc_len - pos, " (type %u)", e_type); break;
    }

    pos += (size_t)snprintf(desc + pos, desc_len - pos, ", %s", elf_machine_name(e_machine));

    if (e_machine == 40 /* EM_ARM */) {
        unsigned int eabi = (e_flags & EF_ARM_EABIMASK) >> 24;

        pos += (size_t)snprintf(desc + pos, desc_len - pos, ", EABI%u", eabi);

        if (e_flags & EF_ARM_ABI_FLOAT_HARD)
            pos += (size_t)snprintf(desc + pos, desc_len - pos, ", hard-float ABI");
        else if (e_flags & EF_ARM_ABI_FLOAT_SOFT)
            pos += (size_t)snprintf(desc + pos, desc_len - pos, ", soft-float ABI");
    }

    interp[0] = '\0';
    elf_walk_program_headers(fd, is64, little_endian, e_phoff, e_phnum, e_phentsize,
                             file_size, &has_interp, interp, sizeof(interp), &has_dynamic);

    if (has_interp) {
        pos += (size_t)snprintf(desc + pos, desc_len - pos, ", dynamically linked");

        if (interp[0])
            pos += (size_t)snprintf(desc + pos, desc_len - pos, ", interpreter %s", interp);
    } else if (e_type == 2 /* ET_EXEC */) {
        pos += (size_t)snprintf(desc + pos, desc_len - pos, ", statically linked");
    }

    symtab = elf_has_symtab(fd, little_endian, e_shoff, e_shnum, e_shentsize, file_size);

    if (symtab == 1)
        pos += (size_t)snprintf(desc + pos, desc_len - pos, ", not stripped");
    else if (symtab == 0)
        pos += (size_t)snprintf(desc + pos, desc_len - pos, ", stripped");

    (void)pos;

    return 1;
}

static int shebang_interpreter(const unsigned char *buf, size_t len, char *interp, size_t interp_len)
{
    size_t i, start;

    if (len < 3 || buf[0] != '#' || buf[1] != '!')
        return 0;

    i = 2;

    while (i < len && (buf[i] == ' ' || buf[i] == '\t'))
        i++;

    start = i;

    while (i < len && buf[i] != '\n' && buf[i] != ' ' && buf[i] != '\t')
        i++;

    if (i == start)
        return 0;

    {
        size_t n = i - start;

        if (n >= interp_len)
            n = interp_len - 1;

        memcpy(interp, buf + start, n);
        interp[n] = '\0';
    }

    return 1;
}

static int file_looks_like_text(const unsigned char *buf, size_t len)
{
    size_t bad = 0;
    size_t i;

    for (i = 0; i < len; i++) {
        unsigned char c = buf[i];

        if (c == '\0')
            return 0;

        if (c == '\n' || c == '\r' || c == '\t')
            continue;

        if (c < 0x20 || c == 0x7f)
            bad++;
    }

    return len == 0 || bad * 100 <= len * 5;
}

static void file_print(const char *path, int brief, const char *desc)
{
    if (brief)
        printf("%s\n", desc);
    else
        printf("%s: %s\n", path, desc);
}

static int describe_regular_file(const char *path, int brief, off_t file_size)
{
    int fd;
    unsigned char prefix[FILE_PREFIX_SIZE];
    ssize_t n;
    char desc[512];
    char interp[128];

    if (file_size == 0) {
        file_print(path, brief, "empty");
        return 0;
    }

    fd = open(path, O_RDONLY);

    if (fd < 0) {
        perror(path);
        return 1;
    }

    n = read(fd, prefix, sizeof(prefix));

    if (n < 0) {
        perror(path);
        close(fd);
        return 1;
    }

    if (n >= 4 && prefix[0] == 0x7f && prefix[1] == 'E' && prefix[2] == 'L' && prefix[3] == 'F') {
        if (describe_elf(fd, prefix, (size_t)n, file_size, desc, sizeof(desc)) != 0) {
            file_print(path, brief, desc);
            close(fd);
            return 0;
        }
    }

    close(fd);

    if (shebang_interpreter(prefix, (size_t)n, interp, sizeof(interp))) {
        snprintf(desc, sizeof(desc), "script, interpreter %s", interp);
        file_print(path, brief, desc);
        return 0;
    }

    if (n >= 2 && prefix[0] == 0x1f && prefix[1] == 0x8b) {
        file_print(path, brief, "gzip compressed data");
        return 0;
    }

    if (n >= 4 && prefix[0] == 'h' && prefix[1] == 's' && prefix[2] == 'q' && prefix[3] == 's') {
        file_print(path, brief, "SquashFS filesystem, little-endian");
        return 0;
    }

    if (file_looks_like_text(prefix, (size_t)n))
        file_print(path, brief, "ASCII text");
    else
        file_print(path, brief, "data");

    return 0;
}

static int describe_path(const char *path, int brief, int follow)
{
    struct stat st;
    int rc;

    rc = follow ? stat(path, &st) : lstat(path, &st);

    if (rc != 0) {
        perror(path);
        return 1;
    }

    if (S_ISLNK(st.st_mode)) {
        char target[PATH_MAX];
        char desc[PATH_MAX + 32];
        ssize_t n = readlink(path, target, sizeof(target) - 1);

        if (n < 0) {
            perror(path);
            return 1;
        }

        target[n] = '\0';
        snprintf(desc, sizeof(desc), "symbolic link to '%s'", target);
        file_print(path, brief, desc);
        return 0;
    }

    if (S_ISDIR(st.st_mode)) {
        file_print(path, brief, "directory");
        return 0;
    }

    if (S_ISCHR(st.st_mode)) {
        file_print(path, brief, "character special file");
        return 0;
    }

    if (S_ISBLK(st.st_mode)) {
        file_print(path, brief, "block special file");
        return 0;
    }

    if (S_ISFIFO(st.st_mode)) {
        file_print(path, brief, "fifo (named pipe)");
        return 0;
    }

    if (S_ISSOCK(st.st_mode)) {
        file_print(path, brief, "socket");
        return 0;
    }

    if (!S_ISREG(st.st_mode)) {
        file_print(path, brief, "unknown file type");
        return 0;
    }

    return describe_regular_file(path, brief, st.st_size);
}

static int cmd_file(int argc, char **argv)
{
    int brief = 0;
    int follow = 0;
    int arg = 1;
    int rc = 0;

    while (arg < argc && argv[arg][0] == '-' && argv[arg][1]) {
        const char *p;

        if (!strcmp(argv[arg], "--")) {
            arg++;
            break;
        }

        for (p = argv[arg] + 1; *p; p++) {
            if (*p == 'b') brief = 1;
            else if (*p == 'L') follow = 1;
            else {
                fprintf(stderr, "Usage: nshbox file [-bL] FILE...\n");
                return 2;
            }
        }

        arg++;
    }

    if (arg >= argc) {
        fprintf(stderr, "Usage: nshbox file [-bL] FILE...\n");
        return 2;
    }

    for (; arg < argc; arg++) {
        if (describe_path(argv[arg], brief, follow) != 0)
            rc = 1;
    }

    return rc;
}


/* ------------------------------------------------------------------ */
/* stat                                                               */
/* ------------------------------------------------------------------ */

static void mode_string(mode_t mode, char out[11])
{
    const char chars[] = "rwxrwxrwx";
    int i;

    out[0] = S_ISDIR(mode) ? 'd' : S_ISLNK(mode) ? 'l' : S_ISCHR(mode) ? 'c' :
             S_ISBLK(mode) ? 'b' : S_ISFIFO(mode) ? 'p' : S_ISSOCK(mode) ? 's' : '-';
    for (i = 0; i < 9; i++)
        out[i + 1] = (mode & (1U << (8 - i))) ? chars[i] : '-';
    if (mode & S_ISUID) out[3] = (out[3] == 'x') ? 's' : 'S';
    if (mode & S_ISGID) out[6] = (out[6] == 'x') ? 's' : 'S';
    if (mode & S_ISVTX) out[9] = (out[9] == 'x') ? 't' : 'T';
    out[10] = '\0';
}

static const char *file_type_name(mode_t mode)
{
    if (S_ISREG(mode))  return "file";
    if (S_ISDIR(mode))  return "directory";
    if (S_ISLNK(mode))  return "symlink";
    if (S_ISCHR(mode))  return "char_device";
    if (S_ISBLK(mode))  return "block_device";
    if (S_ISFIFO(mode)) return "fifo";
    if (S_ISSOCK(mode)) return "socket";
    return "unknown";
}

/* --json: one array of objects, one per file that could be stat'ed (an
 * unreadable path gets its usual message on stderr and a non-zero exit,
 * no entry - same as the text output, which prints nothing for it on
 * stdout either). "mode" is the octal permission string exactly as text
 * mode shows it (JSON has no octal literal); "mtime" is text mode's own
 * formatted string, "mtime_epoch" the same instant as a plain number for
 * consumers that would rather not parse it. Missing-value rule as for
 * sysinfo: "" if the time cannot be formatted, key always present. */
static int cmd_stat(int argc, char **argv)
{
    int i;
    int rc = 0;
    int json = 0;
    int files = 0;
    int count = 0;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0)
            json = 1;
        else
            files++;
    }

    if (files == 0) {
        fprintf(stderr, "Usage: nshbox stat [--json] <file> [...]\n");
        return 1;
    }

    if (json)
        putchar('[');

    for (i = 1; i < argc; i++) {
        struct stat st;
        char mode[11];
        char timebuf[64] = "?";
        int have_time = 0;
        struct tm tm;

        if (strcmp(argv[i], "--json") == 0)
            continue;

        if (lstat(argv[i], &st) < 0) {
            perror(argv[i]);
            rc = 1;
            continue;
        }

        mode_string(st.st_mode, mode);
        if (localtime_r(&st.st_mtime, &tm)) {
            strftime(timebuf, sizeof(timebuf), "%Y-%m-%d %H:%M:%S %z", &tm);
            have_time = 1;
        }

        if (json) {
            if (count > 0)
                putchar(',');
            count++;

            fputs("{\"file\":", stdout);
            json_print_string(argv[i]);
            printf(",\"type\":\"%s\",\"size\":%lld,\"mode\":\"%04o\",\"mode_string\":\"%s\","
                   "\"uid\":%lu,\"gid\":%lu,\"links\":%lu,\"mtime\":",
                   file_type_name(st.st_mode),
                   (long long)st.st_size,
                   (unsigned)(st.st_mode & 07777), mode,
                   (unsigned long)st.st_uid,
                   (unsigned long)st.st_gid,
                   (unsigned long)st.st_nlink);
            json_print_string(have_time ? timebuf : "");
            printf(",\"mtime_epoch\":%lld}", (long long)st.st_mtime);
            continue;
        }

        printf("  File: %s\n", argv[i]);
        printf("  Size: %lld\n", (long long)st.st_size);
        printf("  Mode: %04o (%s)\n", (unsigned)(st.st_mode & 07777), mode);
        printf("   UID: %lu\n", (unsigned long)st.st_uid);
        printf("   GID: %lu\n", (unsigned long)st.st_gid);
        printf(" Links: %lu\n", (unsigned long)st.st_nlink);
        printf("Modify: %s\n", timebuf);
        if (i + 1 < argc)
            putchar('\n');
    }

    if (json)
        fputs("]\n", stdout);

    return rc;
}


/* ------------------------------------------------------------------ */
/* head / tail                                                      */
/* ------------------------------------------------------------------ */

static int parse_line_count(int argc, char **argv, long default_n, long *count, int *first_file)
{
    *count = default_n;
    *first_file = 1;

    if (argc >= 3 && strcmp(argv[1], "-n") == 0) {
        char *end;
        long n;

        errno = 0;
        n = strtol(argv[2], &end, 10);
        if (errno || *end || n < 0)
            return -1;
        *count = n;
        *first_file = 3;
    }

    return 0;
}

static int head_stream(FILE *f, long count)
{
    char *line = NULL;
    size_t cap = 0;
    long n = 0;

    while (n < count && getline(&line, &cap, f) >= 0) {
        fputs(line, stdout);
        n++;
    }

    free(line);
    return ferror(f) ? 1 : 0;
}

static int cmd_head(int argc, char **argv)
{
    long count;
    int first;
    int rc = 0;
    int i;

    if (parse_line_count(argc, argv, 10, &count, &first) != 0) {
        fprintf(stderr, "Usage: nshbox head [-n lines] [file ...]\n");
        return 1;
    }

    if (first == argc)
        return head_stream(stdin, count);

    for (i = first; i < argc; i++) {
        FILE *f = fopen(argv[i], "r");
        if (!f) {
            perror(argv[i]);
            rc = 1;
            continue;
        }
        if (head_stream(f, count) != 0)
            rc = 1;
        fclose(f);
    }
    return rc;
}

static int tail_stream(FILE *f, long count)
{
    char **lines;
    size_t *caps;
    long used = 0;
    long pos = 0;
    long i;
    int rc = 0;

    if (count == 0)
        return 0;

    lines = calloc((size_t)count, sizeof(*lines));
    caps = calloc((size_t)count, sizeof(*caps));
    if (!lines || !caps) {
        free(lines);
        free(caps);
        perror("calloc");
        return 1;
    }

    while (getline(&lines[pos], &caps[pos], f) >= 0) {
        pos = (pos + 1) % count;
        if (used < count)
            used++;
    }

    if (ferror(f))
        rc = 1;

    for (i = 0; i < used; i++) {
        long idx = (used == count) ? (pos + i) % count : i;
        fputs(lines[idx], stdout);
    }

    for (i = 0; i < count; i++)
        free(lines[i]);
    free(lines);
    free(caps);
    return rc;
}

static int cmd_tail(int argc, char **argv)
{
    long count;
    int first;
    int rc = 0;
    int i;

    if (parse_line_count(argc, argv, 10, &count, &first) != 0) {
        fprintf(stderr, "Usage: nshbox tail [-n lines] [file ...]\n");
        return 1;
    }

    if (first == argc)
        return tail_stream(stdin, count);

    for (i = first; i < argc; i++) {
        FILE *f = fopen(argv[i], "r");
        if (!f) {
            perror(argv[i]);
            rc = 1;
            continue;
        }
        if (tail_stream(f, count) != 0)
            rc = 1;
        fclose(f);
    }
    return rc;
}


/* ------------------------------------------------------------------ */
/* wc                                                                 */
/* ------------------------------------------------------------------ */

typedef struct {
    unsigned long long lines;
    unsigned long long words;
    unsigned long long bytes;
} wc_count_t;

static int wc_stream(FILE *f, wc_count_t *out)
{
    unsigned char buf[4096];
    size_t n;
    int in_word = 0;

    memset(out, 0, sizeof(*out));
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        size_t i;
        out->bytes += n;
        for (i = 0; i < n; i++) {
            if (buf[i] == '\n')
                out->lines++;
            if (isspace(buf[i])) {
                in_word = 0;
            } else if (!in_word) {
                out->words++;
                in_word = 1;
            }
        }
    }
    return ferror(f) ? 1 : 0;
}

static void wc_print(const wc_count_t *c, int show_l, int show_w, int show_c, const char *name)
{
    if (show_l) printf("%8llu", c->lines);
    if (show_w) printf("%8llu", c->words);
    if (show_c) printf("%8llu", c->bytes);
    if (name) printf(" %s", name);
    putchar('\n');
}

static int cmd_wc(int argc, char **argv)
{
    int show_l = 0, show_w = 0, show_c = 0;
    int arg = 1;
    int rc = 0;
    int files = 0;
    wc_count_t total = {0, 0, 0};

    if (arg < argc && argv[arg][0] == '-' && argv[arg][1]) {
        const char *p = argv[arg] + 1;
        while (*p) {
            if (*p == 'l') show_l = 1;
            else if (*p == 'w') show_w = 1;
            else if (*p == 'c') show_c = 1;
            else {
                fprintf(stderr, "Usage: nshbox wc [-lwc] [file ...]\n");
                return 1;
            }
            p++;
        }
        arg++;
    }

    if (!show_l && !show_w && !show_c)
        show_l = show_w = show_c = 1;

    if (arg == argc) {
        wc_count_t c;
        rc = wc_stream(stdin, &c);
        wc_print(&c, show_l, show_w, show_c, NULL);
        return rc;
    }

    for (; arg < argc; arg++) {
        FILE *f = fopen(argv[arg], "rb");
        wc_count_t c;
        if (!f) {
            perror(argv[arg]);
            rc = 1;
            continue;
        }
        if (wc_stream(f, &c) != 0)
            rc = 1;
        fclose(f);
        wc_print(&c, show_l, show_w, show_c, argv[arg]);
        total.lines += c.lines;
        total.words += c.words;
        total.bytes += c.bytes;
        files++;
    }

    if (files > 1)
        wc_print(&total, show_l, show_w, show_c, "total");
    return rc;
}


/* ------------------------------------------------------------------ */
/* sort                                                               */
/* ------------------------------------------------------------------ */

static int sort_lex_cmp(const void *a, const void *b)
{
    const char *const *sa = a;
    const char *const *sb = b;

    return strcmp(*sa, *sb);
}

static int sort_numeric_cmp(const void *a, const void *b)
{
    const char *const *sa = a;
    const char *const *sb = b;
    double na = atof(*sa);
    double nb = atof(*sb);

    if (na < nb) return -1;
    if (na > nb) return 1;
    return strcmp(*sa, *sb);
}

/* Reads every line of f via getline() and appends each one (still
   newline-terminated, same convention as tail_stream()'s fputs()) as
   its own independently-allocated string onto the caller's growable
   array - line/linecap are reset to NULL/0 after each append so the
   next getline() call allocates a fresh buffer instead of reusing (and
   invalidating) the one just handed off. */
static int sort_append_lines(FILE *f, char ***lines, size_t *count, size_t *cap)
{
    char *line = NULL;
    size_t linecap = 0;
    ssize_t len;

    while ((len = getline(&line, &linecap, f)) >= 0) {
        (void)len;

        if (*count == *cap) {
            size_t newcap = *cap ? *cap * 2 : 64;
            char **grown = realloc(*lines, newcap * sizeof(**lines));

            if (!grown) {
                perror("realloc");
                free(line);
                return 1;
            }

            *lines = grown;
            *cap = newcap;
        }

        (*lines)[(*count)++] = line;
        line = NULL;
        linecap = 0;
    }

    free(line);
    return ferror(f) ? 1 : 0;
}

static int cmd_sort(int argc, char **argv)
{
    int reverse = 0, numeric = 0, unique = 0;
    int arg = 1;
    char **lines = NULL;
    size_t count = 0, cap = 0;
    int rc = 0;
    size_t i;
    int (*cmp)(const void *, const void *);

    if (arg < argc && argv[arg][0] == '-' && argv[arg][1]) {
        const char *p = argv[arg] + 1;

        while (*p) {
            if (*p == 'r') reverse = 1;
            else if (*p == 'n') numeric = 1;
            else if (*p == 'u') unique = 1;
            else {
                fprintf(stderr, "Usage: nshbox sort [-rnu] [file ...]\n");
                return 1;
            }
            p++;
        }
        arg++;
    }

    /* Unlike wc/head/tail (which report per-file results), multiple
       files here are concatenated into one combined list to sort
       together, matching real sort's own traditional behavior. */
    if (arg == argc) {
        if (sort_append_lines(stdin, &lines, &count, &cap) != 0)
            rc = 1;
    } else {
        for (; arg < argc; arg++) {
            FILE *f = fopen(argv[arg], "r");

            if (!f) {
                perror(argv[arg]);
                rc = 1;
                continue;
            }
            if (sort_append_lines(f, &lines, &count, &cap) != 0)
                rc = 1;
            fclose(f);
        }
    }

    cmp = numeric ? sort_numeric_cmp : sort_lex_cmp;
    qsort(lines, count, sizeof(*lines), cmp);

    if (unique && count > 0) {
        size_t out = 1;

        for (i = 1; i < count; i++) {
            if (cmp(&lines[out - 1], &lines[i]) == 0) {
                free(lines[i]);
                continue;
            }
            lines[out++] = lines[i];
        }
        count = out;
    }

    for (i = 0; i < count; i++)
        fputs(lines[reverse ? count - 1 - i : i], stdout);

    for (i = 0; i < count; i++)
        free(lines[i]);
    free(lines);

    return rc;
}


/* ------------------------------------------------------------------ */
/* tee                                                                */
/* ------------------------------------------------------------------ */

static int cmd_tee(int argc, char **argv)
{
    int append = 0;
    int first = 1;
    FILE **files = NULL;
    int file_count;
    unsigned char buf[4096];
    size_t n;
    int rc = 0;
    int i;

    if (first < argc && strcmp(argv[first], "-a") == 0) {
        append = 1;
        first++;
    }

    file_count = argc - first;
    if (file_count > 0) {
        files = calloc((size_t)file_count, sizeof(*files));
        if (!files) {
            perror("calloc");
            return 1;
        }
        for (i = 0; i < file_count; i++) {
            files[i] = fopen(argv[first + i], append ? "ab" : "wb");
            if (!files[i]) {
                perror(argv[first + i]);
                rc = 1;
            }
        }
    }

    while ((n = fread(buf, 1, sizeof(buf), stdin)) > 0) {
        if (fwrite(buf, 1, n, stdout) != n)
            rc = 1;
        for (i = 0; i < file_count; i++) {
            if (files[i] && fwrite(buf, 1, n, files[i]) != n)
                rc = 1;
        }
    }

    if (ferror(stdin))
        rc = 1;
    for (i = 0; i < file_count; i++)
        if (files[i] && fclose(files[i]) != 0)
            rc = 1;
    free(files);
    return rc;
}


/* ------------------------------------------------------------------ */
/* grep                                                               */
/* ------------------------------------------------------------------ */

static int grep_stream(FILE *f, const char *name, regex_t *re,
                       int invert, int number, int quiet, int count_only,
                       int files_with_matches, int show_name, unsigned long *matches)
{
    char *line = NULL;
    size_t cap = 0;
    ssize_t len;
    unsigned long lineno = 0;

    while ((len = getline(&line, &cap, f)) >= 0) {
        int match;
        lineno++;
        match = (regexec(re, line, 0, NULL, 0) == 0);
        if (invert)
            match = !match;
        if (!match)
            continue;

        (*matches)++;
        if (quiet) {
            free(line);
            return 0;
        }
        /* -l: print just the filename and stop at the first match in
           this file, same "no need to keep scanning" short-circuit as
           -q, but reporting the name instead of staying silent. */
        if (files_with_matches) {
            printf("%s\n", name);
            free(line);
            return 0;
        }
        if (count_only)
            continue;

        if (show_name)
            printf("%s:", name);
        if (number)
            printf("%lu:", lineno);
        fwrite(line, 1, (size_t)len, stdout);
        if (len == 0 || line[len - 1] != '\n')
            putchar('\n');
    }

    free(line);
    return ferror(f) ? 1 : 0;
}

/* Recursive directory walk for grep -r, modeled directly on find_walk()
   (see cmd_find above): lstat(), not stat(), so a symlinked directory
   is never seen as S_ISDIR here and recursion naturally cannot follow
   it into a loop - matching plain "-r" (not "-R") in real grep, which
   does not follow symlinks either. Non-regular files found during the
   walk (symlinks, devices, fifos) are silently skipped rather than
   reported as errors, since encountering one while recursing through a
   whole tree is routine, not exceptional. */
static int grep_walk(const char *path, regex_t *re, int invert, int number,
                      int quiet, int count_only, int files_with_matches,
                      unsigned long *total_matches, int *had_error)
{
    struct stat st;

    if (lstat(path, &st) != 0) {
        fprintf(stderr, "grep: %s: %s\n", path, strerror(errno));
        *had_error = 1;
        return 0;
    }

    if (S_ISDIR(st.st_mode)) {
        DIR *dir = opendir(path);
        struct dirent *de;

        if (!dir) {
            fprintf(stderr, "grep: %s: %s\n", path, strerror(errno));
            *had_error = 1;
            return 0;
        }

        while ((de = readdir(dir)) != NULL) {
            char child[PATH_MAX];
            int n;

            if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
                continue;

            if (quiet && *total_matches)
                break;

            n = snprintf(child, sizeof(child), "%s%s%s", path,
                         (path[0] && path[strlen(path) - 1] == '/') ? "" : "/",
                         de->d_name);

            if (n < 0 || (size_t)n >= sizeof(child)) {
                fprintf(stderr, "grep: path too long: %s/%s\n", path, de->d_name);
                *had_error = 1;
                continue;
            }

            grep_walk(child, re, invert, number, quiet, count_only,
                      files_with_matches, total_matches, had_error);
        }

        closedir(dir);
        return 0;
    }

    if (!S_ISREG(st.st_mode))
        return 0;

    {
        FILE *f = fopen(path, "r");
        unsigned long matches = 0;

        if (!f) {
            perror(path);
            *had_error = 1;
            return 0;
        }

        if (grep_stream(f, path, re, invert, number, quiet, count_only,
                        files_with_matches, 1, &matches) != 0)
            *had_error = 1;

        fclose(f);
        *total_matches += matches;

        if (count_only && !files_with_matches)
            printf("%s:%lu\n", path, matches);
    }

    return 0;
}

static int cmd_grep(int argc, char **argv)
{
    int cflags = REG_NOSUB;
    int invert = 0, number = 0, quiet = 0, count_only = 0, recursive = 0, files_with_matches = 0;
    int arg = 1;
    regex_t re;
    int r;
    int rc = 1;
    unsigned long total_matches = 0;
    int file_count;

    while (arg < argc && argv[arg][0] == '-' && argv[arg][1]) {
        const char *p;
        if (strcmp(argv[arg], "--") == 0) {
            arg++;
            break;
        }
        for (p = argv[arg] + 1; *p; p++) {
            switch (*p) {
                case 'i': cflags |= REG_ICASE; break;
                case 'v': invert = 1; break;
                case 'n': number = 1; break;
                case 'q': quiet = 1; break;
                case 'c': count_only = 1; break;
                case 'E': cflags |= REG_EXTENDED; break;
                case 'r': recursive = 1; break;
                case 'l': files_with_matches = 1; break;
                default:
                    fprintf(stderr, "Usage: nshbox grep [-invqcErl] pattern [file ...]\n");
                    return 2;
            }
        }
        arg++;
    }

    if (arg >= argc) {
        fprintf(stderr, "Usage: nshbox grep [-invqcErl] pattern [file ...]\n");
        return 2;
    }

    r = regcomp(&re, argv[arg++], cflags);
    if (r != 0) {
        char err[256];
        regerror(r, &re, err, sizeof(err));
        fprintf(stderr, "grep: %s\n", err);
        return 2;
    }

    file_count = argc - arg;
    if (recursive) {
        int had_error = 0;
        int i;

        /* No path given: walk the current directory, matching real
           grep's own "grep -r pattern" default. */
        if (file_count == 0) {
            grep_walk(".", &re, invert, number, quiet, count_only,
                      files_with_matches, &total_matches, &had_error);
        } else {
            for (i = arg; i < argc; i++) {
                if (quiet && total_matches)
                    break;
                grep_walk(argv[i], &re, invert, number, quiet, count_only,
                          files_with_matches, &total_matches, &had_error);
            }
        }

        rc = had_error ? 2 : (total_matches ? 0 : 1);
    } else if (file_count == 0) {
        unsigned long matches = 0;
        if (grep_stream(stdin, "(standard input)", &re, invert, number, quiet,
                        count_only, files_with_matches, 0, &matches) != 0) {
            rc = 2;
        } else {
            if (count_only)
                printf("%lu\n", matches);
            rc = matches ? 0 : 1;
        }
    } else {
        int i;
        int had_error = 0;
        for (i = arg; i < argc; i++) {
            FILE *f = fopen(argv[i], "r");
            unsigned long matches = 0;
            if (!f) {
                perror(argv[i]);
                had_error = 1;
                continue;
            }
            if (grep_stream(f, argv[i], &re, invert, number, quiet,
                            count_only, files_with_matches, file_count > 1, &matches) != 0)
                had_error = 1;
            fclose(f);
            total_matches += matches;
            if (count_only && !files_with_matches) {
                if (file_count > 1)
                    printf("%s:", argv[i]);
                printf("%lu\n", matches);
            }
            if (quiet && matches)
                break;
        }
        rc = had_error ? 2 : (total_matches ? 0 : 1);
    }

    regfree(&re);
    return rc;
}


/* ------------------------------------------------------------------ */
/* hostname                                                            */
/* ------------------------------------------------------------------ */

static int cmd_hostname(int argc, char **argv)
{
    char name[256];
    int fqdn = 0;
    int arg;

    /* Unlike the original version of this command, any argument other
       than -f/--fqdn is now a real usage error rather than being
       silently ignored - "nshbox hostname garbage" used to succeed and
       print the plain hostname anyway, which hides a typo instead of
       reporting it. */
    for (arg = 1; arg < argc; arg++) {
        if (strcmp(argv[arg], "-f") == 0 || strcmp(argv[arg], "--fqdn") == 0) {
            fqdn = 1;
            continue;
        }

        fprintf(stderr, "Usage: nshbox hostname [-f]\n");
        return 2;
    }

    if (gethostname(name, sizeof(name)) != 0) {
        perror("hostname");
        return 1;
    }

    name[sizeof(name) - 1] = '\0';

    if (!fqdn) {
        printf("%s\n", name);
        return 0;
    }

    /* -f: resolve the short name to its fully-qualified form via the
       system's normal name resolution (/etc/hosts, then DNS, per
       nsswitch.conf) - getaddrinfo()+AI_CANONNAME is the standard way
       real "hostname -f" implementations do this, and deliberately not
       this file's own dns_query()/res_query() (used by dig/nslookup
       above): that talks raw DNS directly and would skip /etc/hosts
       entirely, which is exactly where a device's own short name is
       often the only place it is defined at all. */
    {
        struct addrinfo hints;
        struct addrinfo *res = NULL;
        int r;

        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_flags = AI_CANONNAME;

        r = getaddrinfo(name, NULL, &hints, &res);

        if (r != 0) {
            fprintf(stderr, "hostname: %s: %s\n", name, gai_strerror(r));
            return 1;
        }

        printf("%s\n", (res->ai_canonname != NULL) ? res->ai_canonname : name);
        freeaddrinfo(res);
    }

    return 0;
}


/* ------------------------------------------------------------------ */
/* DNS lookup (dig, nslookup) - shared backend                        */
/*                                                                     */
/* Queries go through glibc's own stub resolver (res_query()), not a  */
/* hand-rolled DNS client: it is already part of the C runtime this   */
/* project links against unconditionally on the device (unlike        */
/* libcrypto, an optional add-on package - see this file's own top    */
/* comment), and it already handles /etc/resolv.conf, search domains, */
/* and falling back to TCP for an oversized UDP reply - all real      */
/* protocol details a hand-rolled client would otherwise have to get  */
/* right itself. dig and nslookup below share one query+parse         */
/* function and differ only in how they format the result.            */
/* ------------------------------------------------------------------ */

#define DNS_MAX_RECORDS 32

/* 1025: the real worst case for a decoded domain name's PRESENTATION
   (text) form, not its 255-byte wire-format length - a raw byte that
   isn't printable gets escaped as up to 4 characters (e.g. "\255"), so
   ns_rr_name()/dn_expand() can legitimately return something close to
   4x the wire-format limit. Confirmed directly: GCC's own
   -Wformat-truncation analysis on the real arm-linux-gnueabihf-gcc
   computed this exact same bound for ns_rr_name()'s output (2026-09-13),
   which is what these buffers are sized against here, not a guess. */
#define DNS_NAME_LEN 1025

typedef struct {
    char name[DNS_NAME_LEN];
    /* Needs to hold the worst-case MX line: up to 5 digits of
       preference + a space + a full DNS_NAME_LEN-1 character
       expanded name + the terminating NUL. */
    char data[DNS_NAME_LEN + 8];
    unsigned long ttl;
    int type;
} dns_record_t;

static const char *dns_type_name(int type)
{
    switch (type) {
        case ns_t_a:     return "A";
        case ns_t_cname: return "CNAME";
        case ns_t_mx:    return "MX";
        case ns_t_txt:   return "TXT";
        default:         return "?";
    }
}

static int dns_type_from_name(const char *s)
{
    if (strcasecmp(s, "A") == 0)     return ns_t_a;
    if (strcasecmp(s, "CNAME") == 0) return ns_t_cname;
    if (strcasecmp(s, "MX") == 0)    return ns_t_mx;
    if (strcasecmp(s, "TXT") == 0)   return ns_t_txt;
    return -1;
}

/* Decodes one resource record's rdata into a human-readable string,
   based on its type. CNAME/MX carry a (possibly compressed) domain
   name in rdata - dn_expand() needs the whole message buffer to
   resolve compression pointers, not just the rdata slice, which is
   why this takes the parsed message handle too, not just the record. */
static void dns_decode_rdata(ns_msg handle, ns_rr rr, char *out, size_t outlen)
{
    int type = ns_rr_type(rr);
    const unsigned char *rdata = ns_rr_rdata(rr);
    size_t rdlen = ns_rr_rdlen(rr);

    if (type == ns_t_a && rdlen == 4) {
        struct in_addr addr;
        memcpy(&addr, rdata, 4);
        snprintf(out, outlen, "%s", inet_ntoa(addr));
        return;
    }

    if (type == ns_t_cname) {
        char expanded[DNS_NAME_LEN];

        if (dn_expand(ns_msg_base(handle), ns_msg_end(handle), rdata, expanded, sizeof(expanded)) >= 0)
            snprintf(out, outlen, "%s", expanded);
        else
            snprintf(out, outlen, "(unparsable)");
        return;
    }

    if (type == ns_t_mx && rdlen > 2) {
        unsigned int pref = ns_get16(rdata);
        char expanded[DNS_NAME_LEN];

        if (dn_expand(ns_msg_base(handle), ns_msg_end(handle), rdata + 2, expanded, sizeof(expanded)) >= 0)
            snprintf(out, outlen, "%u %s", pref, expanded);
        else
            snprintf(out, outlen, "%u (unparsable)", pref);
        return;
    }

    if (type == ns_t_txt) {
        /* One or more length-prefixed character-strings back to back
           (RFC 1035 3.3.14) - concatenated here rather than shown as
           separate segments, since a single logical TXT value (e.g.
           SPF/DKIM) is routinely split across several of these by
           whatever wrote the zone, purely because of the 255-byte
           limit per character-string. */
        size_t pos = 0;
        size_t written = 0;

        out[0] = '\0';

        while (pos < rdlen) {
            unsigned int seglen = rdata[pos];
            pos++;

            if (pos + seglen > rdlen)
                break;

            if (written + seglen + 1 < outlen) {
                memcpy(out + written, rdata + pos, seglen);
                written += seglen;
                out[written] = '\0';
            }

            pos += seglen;
        }
        return;
    }

    snprintf(out, outlen, "(unsupported type)");
}

/* Runs one DNS query for "name"/"type" and fills "records" with up to
   max_records parsed answers, restricted to records actually matching
   "type" (a query can legitimately come back with unrelated records
   too, e.g. a CNAME chain when asking for A - not interpreted here).
   Returns the number of records found (0 is a real, valid "no data"
   answer, not an error), or -1 on a genuine query failure (name does
   not exist, server unreachable, etc.) - h_errno carries the specific
   reason on failure, same as any other res_query() caller. */
static int dns_query(const char *name, int type, dns_record_t *records, int max_records)
{
    unsigned char answer[4096];
    int len;
    ns_msg handle;
    int count;
    int i;
    int out = 0;

    len = res_query(name, ns_c_in, type, answer, sizeof(answer));

    if (len < 0)
        return -1;

    if (ns_initparse(answer, len, &handle) < 0)
        return -1;

    count = ns_msg_count(handle, ns_s_an);

    for (i = 0; i < count && out < max_records; i++) {
        ns_rr rr;

        if (ns_parserr(&handle, ns_s_an, i, &rr) != 0)
            continue;

        if ((int)ns_rr_type(rr) != type)
            continue;

        snprintf(records[out].name, sizeof(records[out].name), "%s", ns_rr_name(rr));
        records[out].ttl = ns_rr_ttl(rr);
        records[out].type = (int)ns_rr_type(rr);
        dns_decode_rdata(handle, rr, records[out].data, sizeof(records[out].data));
        out++;
    }

    return out;
}

/* Shared by both dig --json and nslookup --json - they query and parse
   identically (see this section's own top comment), so there is no
   reason for their JSON shape to differ just because their plain-text
   output does. Always prints a valid JSON array, even "[]" for zero
   records - a caller piping this into "jq" gets parseable output
   whether or not anything matched; success/failure is still signaled
   the normal way, via the exit code and an stderr message. */
static void dns_print_json(const dns_record_t *records, int count)
{
    int i;

    printf("[");
    for (i = 0; i < count; i++) {
        if (i > 0)
            printf(",");
        printf("{\"name\":");
        json_print_string(records[i].name);
        printf(",\"ttl\":%lu,\"type\":", records[i].ttl);
        json_print_string(dns_type_name(records[i].type));
        printf(",\"data\":");
        json_print_string(records[i].data);
        printf("}");
    }
    printf("]\n");
}

static int cmd_dig(int argc, char **argv)
{
    const char *positional[2] = { NULL, NULL };
    int npositional = 0;
    int json = 0;
    const char *name;
    int type = ns_t_a;
    dns_record_t records[DNS_MAX_RECORDS];
    int count;
    int i;
    int arg;

    for (arg = 1; arg < argc; arg++) {
        if (strcmp(argv[arg], "--json") == 0) {
            json = 1;
            continue;
        }

        if (npositional >= 2) {
            fprintf(stderr, "Usage: nshbox dig [--json] <name> [A|CNAME|MX|TXT]\n");
            return 2;
        }

        positional[npositional++] = argv[arg];
    }

    if (npositional < 1) {
        fprintf(stderr, "Usage: nshbox dig [--json] <name> [A|CNAME|MX|TXT]\n");
        return 2;
    }

    name = positional[0];

    if (npositional == 2) {
        type = dns_type_from_name(positional[1]);
        if (type < 0) {
            fprintf(stderr, "dig: unknown type '%s' (supported: A, CNAME, MX, TXT)\n", positional[1]);
            return 2;
        }
    }

    count = dns_query(name, type, records, DNS_MAX_RECORDS);

    if (count < 0) {
        fprintf(stderr, "dig: %s: %s\n", name, hstrerror(h_errno));
        if (json)
            printf("[]\n");
        return 1;
    }

    if (count == 0) {
        fprintf(stderr, "dig: %s: no %s record found\n", name, dns_type_name(type));
        if (json)
            printf("[]\n");
        return 1;
    }

    if (json) {
        dns_print_json(records, count);
        return 0;
    }

    printf(";; ANSWER SECTION:\n");
    for (i = 0; i < count; i++) {
        printf("%-24s %6lu IN %-6s %s\n",
               records[i].name, records[i].ttl,
               dns_type_name(records[i].type), records[i].data);
    }

    return 0;
}

static int cmd_nslookup(int argc, char **argv)
{
    const char *name = NULL;
    int type = ns_t_a;
    int json = 0;
    dns_record_t records[DNS_MAX_RECORDS];
    int count;
    int i;
    int arg;

    for (arg = 1; arg < argc; arg++) {
        if (strcmp(argv[arg], "--json") == 0) {
            json = 1;
            continue;
        }

        if (strncmp(argv[arg], "-type=", 6) == 0) {
            type = dns_type_from_name(argv[arg] + 6);
            if (type < 0) {
                fprintf(stderr, "nslookup: unknown type '%s' (supported: A, CNAME, MX, TXT)\n", argv[arg] + 6);
                return 2;
            }
            continue;
        }

        if (name != NULL) {
            fprintf(stderr, "Usage: nshbox nslookup [--json] [-type=A|CNAME|MX|TXT] <name>\n");
            return 2;
        }

        name = argv[arg];
    }

    if (name == NULL) {
        fprintf(stderr, "Usage: nshbox nslookup [--json] [-type=A|CNAME|MX|TXT] <name>\n");
        return 2;
    }

    count = dns_query(name, type, records, DNS_MAX_RECORDS);

    if (count < 0) {
        fprintf(stderr, "nslookup: %s: %s\n", name, hstrerror(h_errno));
        if (json)
            printf("[]\n");
        return 1;
    }

    if (count == 0) {
        fprintf(stderr, "nslookup: %s: no %s record found\n", name, dns_type_name(type));
        if (json)
            printf("[]\n");
        return 1;
    }

    if (json) {
        dns_print_json(records, count);
        return 0;
    }

    for (i = 0; i < count; i++) {
        switch (records[i].type) {
            case ns_t_a:
                printf("Name:\t%s\n", records[i].name);
                printf("Address: %s\n", records[i].data);
                break;
            case ns_t_cname:
                printf("%s\tcanonical name = %s\n", records[i].name, records[i].data);
                break;
            case ns_t_mx:
                printf("%s\tmail exchanger = %s\n", records[i].name, records[i].data);
                break;
            case ns_t_txt:
                printf("%s\ttext = \"%s\"\n", records[i].name, records[i].data);
                break;
            default:
                printf("%s\t%s\n", records[i].name, records[i].data);
                break;
        }
    }

    return 0;
}


/* ------------------------------------------------------------------ */
/* Command table                                                      */
/* ------------------------------------------------------------------ */

static void du_format(uint64_t bytes, int human, int apparent, char *buf, size_t buflen)
{
    static const char units[] = "BKMGTPE";

    if (human) {
        double value = (double)bytes;
        unsigned int unit = 0;

        while (value >= 1024.0 && unit < sizeof(units) - 2) {
            value /= 1024.0;
            unit++;
        }

        if (unit == 0)
            snprintf(buf, buflen, "%llu", (unsigned long long)bytes);
        else if (value < 10.0)
            snprintf(buf, buflen, "%.1f%c", value, units[unit]);
        else
            snprintf(buf, buflen, "%.0f%c", value, units[unit]);
    } else if (apparent) {
        snprintf(buf, buflen, "%llu", (unsigned long long)bytes);
    } else {
        /* Traditional du output is in 1 KiB units. */
        snprintf(buf, buflen, "%llu",
                 (unsigned long long)((bytes + 1023) / 1024));
    }
}

/* json/first thread the same way find_walk()'s options struct does -
   *first tracks whether a leading comma is needed, shared across the
   whole recursive walk (not just one directory's own children), since
   any call at any depth might be the one that prints the first entry. */
static int du_path(const char *path, int human, int summary, int apparent,
                   int top_level, uint64_t *total_out, int json, int *first)
{
    struct stat st;
    uint64_t total;

    if (lstat(path, &st) != 0) {
        fprintf(stderr, "du: %s: %s\n", path, strerror(errno));
        return 1;
    }

    /* A directory's OWN size/blocks (its entry-table metadata, not its
       contents) is never counted here - confirmed directly against real
       GNU du (2026-09-14, caught by tests/nshbox/test_du.cpp): "du -b" on
       an empty directory reports 0, not the directory inode's own
       st_size (4096 on a typical ext4 block), and a tree's -sb total is
       exactly the sum of the files under it, nothing more. Only a
       non-directory entry (file, symlink) contributes its own size;
       every directory's total is purely the sum of what is under it. */
    total = S_ISDIR(st.st_mode) ? 0 : (apparent ? (uint64_t)st.st_size : (uint64_t)st.st_blocks * 512ULL);

    if (S_ISDIR(st.st_mode)) {
        DIR *dir = opendir(path);
        struct dirent *de;

        if (!dir) {
            fprintf(stderr, "du: %s: %s\n", path, strerror(errno));
            return 1;
        }

        while ((de = readdir(dir)) != NULL) {
            char child[PATH_MAX];
            uint64_t child_total = 0;
            int n;

            if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
                continue;

            n = snprintf(child, sizeof(child), "%s%s%s", path,
                         (path[0] && path[strlen(path) - 1] == '/') ? "" : "/",
                         de->d_name);
            if (n < 0 || (size_t)n >= sizeof(child)) {
                fprintf(stderr, "du: path too long: %s/%s\n", path, de->d_name);
                closedir(dir);
                return 1;
            }

            if (du_path(child, human, summary, apparent, 0, &child_total, json, first) != 0) {
                closedir(dir);
                return 1;
            }
            total += child_total;
        }

        closedir(dir);
    }

    if (top_level || (!summary && S_ISDIR(st.st_mode))) {
        if (json) {
            /* Raw bytes always, regardless of -h/-b - a JSON consumer
               wants a real number, not a display-formatted string; -b's
               apparent-vs-block-count choice is still a real semantic
               difference in what "size" means, so that part of it still
               applies, but -h's human-readable rounding does not. */
            if (!*first)
                putchar(',');
            *first = 0;

            printf("{\"path\":");
            json_print_string(path);
            printf(",\"bytes\":%llu}", (unsigned long long)total);
        } else {
            char sizebuf[32];
            du_format(total, human, apparent, sizebuf, sizeof(sizebuf));
            printf("%s\t%s\n", sizebuf, path);
        }
    }

    *total_out = total;
    return 0;
}

static int cmd_du(int argc, char **argv)
{
    int human = 0;
    int summary = 0;
    int apparent = 0;
    int json = 0;
    int first = 1;
    int argi = 1;
    int rc = 0;

    while (argi < argc && argv[argi][0] == '-' && argv[argi][1]) {
        const char *p;

        if (!strcmp(argv[argi], "--")) {
            argi++;
            break;
        }

        if (!strcmp(argv[argi], "--json")) {
            json = 1;
            argi++;
            continue;
        }

        for (p = argv[argi] + 1; *p; p++) {
            if (*p == 'h') human = 1;
            else if (*p == 's') summary = 1;
            else if (*p == 'b') apparent = 1;
            else {
                fprintf(stderr, "Usage: du [-hsb] [--json] [path ...]\n");
                return 2;
            }
        }
        argi++;
    }

    if (json)
        putchar('[');

    if (argi == argc) {
        uint64_t total = 0;
        rc = du_path(".", human, summary, apparent, 1, &total, json, &first);
    } else {
        for (; argi < argc; argi++) {
            uint64_t total = 0;
            if (du_path(argv[argi], human, summary, apparent, 1, &total, json, &first) != 0)
                rc = 1;
        }
    }

    if (json)
        fputs("]\n", stdout);

    return rc;
}


/* ------------------------------------------------------------------ */
/* find                                                               */
/* ------------------------------------------------------------------ */

typedef struct {
    const char *name_pattern;   /* NULL = no -name filter */
    char        type_filter;    /* 0 = no -type filter, else 'f'/'d'/'l' */
    int         maxdepth;       /* -1 = unlimited */
} find_opts_t;

static int find_type_matches(char type_filter, mode_t mode)
{
    if (type_filter == 0)
        return 1;

    switch (type_filter) {
        case 'f': return S_ISREG(mode);
        case 'd': return S_ISDIR(mode);
        case 'l': return S_ISLNK(mode);
        default:  return 0;
    }
}

/* 'f'/'d'/'l' - the same three types -type already filters on; anything
   else (device, fifo, socket) falls back to '?' rather than guessing at
   a convention nothing in this project's own -type filter recognizes. */
static char find_type_char(mode_t mode)
{
    if (S_ISREG(mode))  return 'f';
    if (S_ISDIR(mode))  return 'd';
    if (S_ISLNK(mode))  return 'l';
    return '?';
}

static int find_walk(const char *path, const find_opts_t *opts, int depth,
                      int json, int *first)
{
    struct stat st;
    const char *base;
    int rc = 0;

    if (lstat(path, &st) != 0) {
        fprintf(stderr, "find: %s: %s\n", path, strerror(errno));
        return 1;
    }

    base = strrchr(path, '/');
    base = base ? base + 1 : path;

    if ((opts->name_pattern == NULL || fnmatch(opts->name_pattern, base, 0) == 0) &&
            find_type_matches(opts->type_filter, st.st_mode)) {
        if (json) {
            if (!*first)
                putchar(',');
            *first = 0;

            printf("{\"path\":");
            json_print_string(path);
            /* size/uid/gid, same field meaning as "nshbox stat"'s own
               Size/UID/GID (plain numeric there too, no username/group
               resolution) - no reason for this project's two size/owner
               reporters to disagree on shape. */
            printf(",\"type\":\"%c\",\"size\":%lld,\"uid\":%lu,\"gid\":%lu}",
                   find_type_char(st.st_mode), (long long)st.st_size,
                   (unsigned long)st.st_uid, (unsigned long)st.st_gid);
        } else {
            printf("%s\n", path);
        }
    }

    if (S_ISDIR(st.st_mode) && (opts->maxdepth < 0 || depth < opts->maxdepth)) {
        DIR *dir;
        struct dirent *de;

        dir = opendir(path);

        if (!dir) {
            fprintf(stderr, "find: %s: %s\n", path, strerror(errno));
            return 1;
        }

        while ((de = readdir(dir)) != NULL) {
            char child[PATH_MAX];
            int n;

            if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
                continue;

            n = snprintf(child, sizeof(child), "%s%s%s", path,
                         (path[0] && path[strlen(path) - 1] == '/') ? "" : "/",
                         de->d_name);

            if (n < 0 || (size_t)n >= sizeof(child)) {
                fprintf(stderr, "find: path too long: %s/%s\n", path, de->d_name);
                rc = 1;
                continue;
            }

            if (find_walk(child, opts, depth + 1, json, first) != 0)
                rc = 1;
        }

        closedir(dir);
    }

    return rc;
}

static int cmd_find(int argc, char **argv)
{
    static const char usage_msg[] =
        "Usage: nshbox find [path ...] [-name pattern] [-type f|d|l] [-maxdepth n] [--json]\n";

    find_opts_t opts;
    const char **paths;
    int path_count = 0;
    int argi = 1;
    int rc = 0;
    int i;
    int json = 0;
    int first = 1;

    opts.name_pattern = NULL;
    opts.type_filter = 0;
    opts.maxdepth = -1;

    paths = calloc((size_t)argc, sizeof(*paths));

    if (!paths) {
        perror("calloc");
        return 1;
    }

    while (argi < argc) {
        if (!strcmp(argv[argi], "--json")) {
            json = 1;
            argi++;
        } else if (!strcmp(argv[argi], "-name")) {
            if (++argi >= argc) {
                fprintf(stderr, "%s", usage_msg);
                free(paths);
                return 2;
            }
            opts.name_pattern = argv[argi++];
        } else if (!strcmp(argv[argi], "-type")) {
            if (++argi >= argc || argv[argi][0] == '\0' || argv[argi][1] != '\0' ||
                    strchr("fdl", argv[argi][0]) == NULL) {
                fprintf(stderr, "%s", usage_msg);
                free(paths);
                return 2;
            }
            opts.type_filter = argv[argi++][0];
        } else if (!strcmp(argv[argi], "-maxdepth")) {
            char *end;
            long n;

            if (++argi >= argc) {
                fprintf(stderr, "%s", usage_msg);
                free(paths);
                return 2;
            }

            errno = 0;
            n = strtol(argv[argi], &end, 10);

            if (errno || *end || n < 0) {
                fprintf(stderr, "find: invalid -maxdepth: %s\n", argv[argi]);
                free(paths);
                return 2;
            }

            opts.maxdepth = (int)n;
            argi++;
        } else if (argv[argi][0] == '-') {
            fprintf(stderr, "find: unsupported option: %s\n", argv[argi]);
            free(paths);
            return 2;
        } else {
            paths[path_count++] = argv[argi++];
        }
    }

    if (path_count == 0)
        paths[path_count++] = ".";

    if (json)
        putchar('[');

    for (i = 0; i < path_count; i++) {
        if (find_walk(paths[i], &opts, 0, json, &first) != 0)
            rc = 1;
    }

    if (json)
        fputs("]\n", stdout);

    free(paths);
    return rc;
}


/* ------------------------------------------------------------------ */
/* tree                                                                */
/*                                                                      */
/* Directory-tree renderer, box-drawing style reused from pstree's own */
/* connector characters (see pstree_print_children() above) - but      */
/* unlike pstree's process tree, every entry always gets its own line  */
/* here: pstree's "single child stays on the current line" compacting  */
/* is specific to how the real Linux pstree(1) renders process chains  */
/* and has no equivalent in a real tree(1) either. Unlike pstree's own */
/* children[] buffer, this one is heap-allocated per call, not a       */
/* shared "static" array - a static buffer here would alias across     */
/* recursive calls the same way it does in pstree_print_children()     */
/* (flagged separately, not fixed here since tree is new code and that */
/* is existing code).                                                  */
/*                                                                      */
/* Shows every entry, including dotfiles - unlike real tree(1), which  */
/* hides them by default (needs -a) - matching this project's own      */
/* find command, which has no hidden-file filtering either.            */
/* ------------------------------------------------------------------ */

#define TREE_MAX_ENTRIES 4096
#define TREE_MAX_DEPTH   64
#define TREE_PREFIX_MAX  1024

typedef struct {
    char name[256];
    unsigned char is_dir;  /* from lstat() - a symlink to a directory is
                               NOT treated as a directory, matching
                               find_walk()'s own lstat-based S_ISDIR
                               check, so tree never follows a symlink
                               into a cycle */
} tree_entry_t;

static int tree_entry_cmp(const void *a, const void *b)
{
    return strcmp(((const tree_entry_t *)a)->name, ((const tree_entry_t *)b)->name);
}

/* readlink() does not NUL-terminate - same handling as cmd_readlink().
   Leaves out[0] as '\0' if path is not a symlink or is unreadable. */
static void tree_read_link(const char *path, char *out, size_t out_size)
{
    ssize_t n;

    out[0] = '\0';

    n = readlink(path, out, out_size - 1);

    if (n > 0)
        out[n] = '\0';
}

static void tree_join(char *out, size_t out_size, const char *dir, const char *name)
{
    snprintf(out, out_size, "%s%s%s", dir,
             (dir[0] && dir[strlen(dir) - 1] == '/') ? "" : "/", name);
}

/* depth counts levels of CHILDREN already descended into, starting at 1
   for the root's own direct entries - matches real tree(1)'s -L
   semantics (-L 1 = root's immediate contents only), not find's own
   0-based -maxdepth (see cmd_find above) - the two commands document
   their own depth flags separately, deliberately not sharing a name.
   is_root is 1 only for cmd_tree()'s own top-level call, 0 for every
   recursive call this function makes into a subdirectory - see its use
   below for why. */
static void tree_walk(const char *path, int max_level, int depth, int is_root,
                       const char *prefix, unsigned long *dirs, unsigned long *files)
{
    DIR *d;
    struct dirent *de;
    tree_entry_t *entries;
    int count = 0;
    int i;

    if (depth > TREE_MAX_DEPTH) {
        fprintf(stderr, "tree: %s: too deep (> %d levels), not descending further\n",
                path, TREE_MAX_DEPTH);
        return;
    }

    d = opendir(path);

    if (!d) {
        fprintf(stderr, "tree: %s: %s\n", path, strerror(errno));
        return;
    }

    entries = malloc((size_t)TREE_MAX_ENTRIES * sizeof(*entries));

    if (!entries) {
        perror("tree: malloc");
        closedir(d);
        return;
    }

    while (count < TREE_MAX_ENTRIES && (de = readdir(d)) != NULL) {
        char child[PATH_MAX];
        struct stat st;

        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
            continue;

        tree_join(child, sizeof(child), path, de->d_name);

        if (lstat(child, &st) != 0)
            continue;

        strncpy(entries[count].name, de->d_name, sizeof(entries[count].name) - 1);
        entries[count].name[sizeof(entries[count].name) - 1] = '\0';
        entries[count].is_dir = S_ISDIR(st.st_mode) ? 1 : 0;
        count++;
    }

    if (count == TREE_MAX_ENTRIES)
        fprintf(stderr, "tree: %s: more than %d entries, output truncated\n", path, TREE_MAX_ENTRIES);

    closedir(d);

    /* The root path itself counts as one directory in the final summary
       - but only if it actually has something in it. Confirmed directly
       against real tree(1) (2026-09-14, caught by tests/nshbox/test_tree.cpp):
       an empty directory reports "0 directories, 0 files", while any
       non-empty one reports its own root as directory #1 on top of
       whatever is found inside - e.g. a root containing one empty
       subdirectory reports "2 directories" (the root plus that one
       subdirectory), not 1. Tied to this level's own "count" (entries
       found in THIS directory) rather than a separate check, since that
       is exactly the "was the root non-empty" condition, and is_root
       ensures this only ever fires once, for cmd_tree()'s own top-level
       call - every recursive call below passes is_root=0. */
    if (is_root && count > 0)
        (*dirs)++;

    qsort(entries, (size_t)count, sizeof(*entries), tree_entry_cmp);

    for (i = 0; i < count; i++) {
        int is_last = (i == count - 1);
        char child[PATH_MAX];
        char link_target[PATH_MAX];

        tree_join(child, sizeof(child), path, entries[i].name);

        printf("%s%s%s", prefix,
               is_last ? "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 " : "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ",
               entries[i].name);

        tree_read_link(child, link_target, sizeof(link_target));

        if (link_target[0])
            printf(" -> %s", link_target);

        putchar('\n');

        if (entries[i].is_dir) {
            (*dirs)++;

            if (max_level < 0 || depth < max_level) {
                char child_prefix[TREE_PREFIX_MAX];
                int n = snprintf(child_prefix, sizeof(child_prefix), "%s%s", prefix,
                                  is_last ? "    " : "\xe2\x94\x82   ");

                if (n < 0 || (size_t)n >= sizeof(child_prefix))
                    fprintf(stderr, "tree: %s: path too deep to render\n", child);
                else
                    tree_walk(child, max_level, depth + 1, 0, child_prefix, dirs, files);
            }
        } else {
            (*files)++;
        }
    }

    free(entries);
}

static int cmd_tree(int argc, char **argv)
{
    static const char usage_msg[] = "Usage: nshbox tree [-L level] [path]\n";
    const char *path = ".";
    int max_level = -1;
    int argi = 1;
    unsigned long dirs = 0;
    unsigned long files = 0;
    struct stat st;

    while (argi < argc) {
        if (!strcmp(argv[argi], "-L")) {
            char *end;
            long n;

            if (++argi >= argc) {
                fprintf(stderr, "%s", usage_msg);
                return 2;
            }

            errno = 0;
            n = strtol(argv[argi], &end, 10);

            if (errno || *end || n < 1) {
                fprintf(stderr, "tree: invalid -L level: %s\n", argv[argi]);
                return 2;
            }

            max_level = (int)n;
            argi++;
        } else if (argv[argi][0] == '-') {
            fprintf(stderr, "tree: unsupported option: %s\n", argv[argi]);
            return 2;
        } else {
            path = argv[argi++];
        }
    }

    if (argi != argc) {
        fprintf(stderr, "%s", usage_msg);
        return 2;
    }

    if (lstat(path, &st) != 0) {
        perror(path);
        return 1;
    }

    if (!S_ISDIR(st.st_mode)) {
        fprintf(stderr, "tree: %s: not a directory\n", path);
        return 1;
    }

    printf("%s\n", path);

    /* is_root=1: tree_walk() itself decides whether the root counts as
       a directory in the summary - see its own comment on that (only
       if the root actually has something in it, matching real tree(1)'s
       confirmed behavior on an empty directory). */
    tree_walk(path, max_level, 1, 1, "", &dirs, &files);
    printf("\n%lu director%s, %lu file%s\n",
           dirs, dirs == 1 ? "y" : "ies", files, files == 1 ? "" : "s");

    return 0;
}


/* ------------------------------------------------------------------ */
/* tar - minimal ustar create/extract, no compression                 */
/*                                                                     */
/* Just enough to move a directory tree over adb push/pull as one      */
/* file instead of many: -c/-x, -f archive, -C dir (changes directory  */
/* before adding/extracting, resolved against the ORIGINAL cwd for the */
/* archive path itself - order of -C relative to -f never matters      */
/* here, unlike real tar). No compression, no symlinks/devices, no     */
/* ownership/permission preservation beyond the low 9 mode bits, no    */
/* GNU long-name extension - names must fit the plain 100-byte ustar   */
/* field. Files are expected to be small (config/terminfo/dist-sized), */
/* so sizes are handled as plain "unsigned long" via fseek, not         */
/* fseeko/off_t - fine well past anything this project ships, but not  */
/* a general-purpose multi-gigabyte tar replacement.                   */
/* ------------------------------------------------------------------ */

#define TAR_BLOCK_SIZE   512
#define TAR_NAME_LEN     100

#define TAR_OFF_NAME     0
#define TAR_OFF_MODE     100
#define TAR_OFF_UID      108
#define TAR_OFF_GID      116
#define TAR_OFF_SIZE     124
#define TAR_OFF_MTIME    136
#define TAR_OFF_CHKSUM   148
#define TAR_OFF_TYPEFLAG 156
#define TAR_OFF_LINKNAME 157
#define TAR_LINKNAME_LEN 100
#define TAR_OFF_MAGIC    257

static void tar_write_octal(unsigned char *field, size_t field_len, unsigned long value)
{
    snprintf((char *)field, field_len, "%0*lo", (int)field_len - 1, value);
}

static unsigned long tar_read_octal(const unsigned char *field, size_t field_len)
{
    char buf[32];
    size_t n = field_len < sizeof(buf) ? field_len : sizeof(buf) - 1;

    memcpy(buf, field, n);
    buf[n] = '\0';

    return strtoul(buf, NULL, 8);
}

/* Set once by cmd_tar() before calling tar_create()/tar_extract(), not
 * threaded as a parameter through every tar_add_*()/tar_write_header()
 * call - nshbox runs one command per process, so there is no reentrancy
 * concern within a single "tar" invocation, and a global here avoids
 * widening half a dozen function signatures for one rarely-used flag.
 */
static int tar_verbose = 0;

static int tar_write_header(FILE *f, const char *name, char typeflag, mode_t mode,
                             off_t size, time_t mtime, const char *linkname)
{
    unsigned char hdr[TAR_BLOCK_SIZE];
    char namebuf[TAR_NAME_LEN + 2];   /* +1 trailing '/' for dirs, +1 NUL */
    size_t namelen;
    int is_dir = (typeflag == '5');
    unsigned long sum;
    size_t i;

    /* GNU tar's own long-standing default: strip leading "/" so a
       member's STORED name is always relative to wherever it later gets
       extracted (-C, or the current directory), never a literal absolute
       path on whatever machine happens to run "tar -x". Confirmed the
       hard way (2026-09-13): archiving /etc without this baked absolute
       paths like "/etc/build.prop" into the archive, so "tar -x" (no -C)
       tried to overwrite the REAL /etc/build.prop - a read-only squashfs
       here, but a real, silent overwrite risk on any writable filesystem.
       tar_add_path()/tar_add_dir() still need the real, unstripped path
       for actual lstat()/opendir()/fopen() calls - only what gets WRITTEN
       into the header changes here. */
    while (*name == '/')
        name++;

    namelen = strlen(name);

    if (namelen + (is_dir ? 1 : 0) >= sizeof(namebuf) - 1) {
        fprintf(stderr, "tar: name too long (max %d chars): %s\n", TAR_NAME_LEN - 1, name);
        return 1;
    }

    if (linkname && strlen(linkname) >= TAR_LINKNAME_LEN) {
        fprintf(stderr, "tar: %s: link target too long (max %d chars): %s\n",
                name, TAR_LINKNAME_LEN - 1, linkname);
        return 1;
    }

    if (is_dir)
        snprintf(namebuf, sizeof(namebuf), "%s/", name);
    else
        strcpy(namebuf, name);

    memset(hdr, 0, sizeof(hdr));
    memcpy(hdr + TAR_OFF_NAME, namebuf, strlen(namebuf));

    tar_write_octal(hdr + TAR_OFF_MODE, 8, (unsigned long)(mode & 07777));
    tar_write_octal(hdr + TAR_OFF_UID, 8, 0);
    tar_write_octal(hdr + TAR_OFF_GID, 8, 0);
    /* Symlinks carry their target in the linkname field, not file data -
       always zero-length in the archive, same as directories. */
    tar_write_octal(hdr + TAR_OFF_SIZE, 12, (is_dir || typeflag == '2') ? 0UL : (unsigned long)size);
    tar_write_octal(hdr + TAR_OFF_MTIME, 12, (unsigned long)mtime);
    hdr[TAR_OFF_TYPEFLAG] = typeflag;

    if (linkname)
        memcpy(hdr + TAR_OFF_LINKNAME, linkname, strlen(linkname));

    memcpy(hdr + TAR_OFF_MAGIC, "ustar", 6);   /* "ustar\0" - the 6 includes the literal's own NUL */
    hdr[TAR_OFF_MAGIC + 6] = '0';
    hdr[TAR_OFF_MAGIC + 7] = '0';

    memset(hdr + TAR_OFF_CHKSUM, ' ', 8);
    sum = 0;
    for (i = 0; i < TAR_BLOCK_SIZE; i++)
        sum += hdr[i];
    snprintf((char *)(hdr + TAR_OFF_CHKSUM), 7, "%06lo", sum);
    hdr[TAR_OFF_CHKSUM + 7] = ' ';

    if (fwrite(hdr, 1, TAR_BLOCK_SIZE, f) != TAR_BLOCK_SIZE) {
        fprintf(stderr, "tar: write error\n");
        return 1;
    }

    /* Always stderr, never stdout - "-f -" may mean the archive itself IS
     * this process's stdout (see tar_create()), and verbose names must
     * never end up interleaved into that byte stream. */
    if (tar_verbose)
        fprintf(stderr, "%s\n", namebuf);

    return 0;
}

static int tar_write_padding(FILE *f, off_t size)
{
    size_t rem = (size_t)(size % TAR_BLOCK_SIZE);
    unsigned char zero[TAR_BLOCK_SIZE];
    size_t pad;

    if (rem == 0)
        return 0;

    pad = TAR_BLOCK_SIZE - rem;
    memset(zero, 0, sizeof(zero));

    if (fwrite(zero, 1, pad, f) != pad) {
        fprintf(stderr, "tar: write error\n");
        return 1;
    }

    return 0;
}

static int tar_add_path(FILE *f, const char *path);

static int tar_add_file(FILE *f, const char *path, const struct stat *st)
{
    FILE *in;
    unsigned char buf[TAR_BLOCK_SIZE];
    off_t remaining = st->st_size;

    /* ustar's 12-byte octal size field holds at most 11 digits - 8^11-1
       bytes (~8GB). Checked explicitly rather than letting
       tar_write_octal() silently truncate a value that does not fit. */
    if ((unsigned long long)st->st_size > 0777777777777ULL) {
        fprintf(stderr, "tar: %s: too large for ustar format\n", path);
        return 1;
    }

    if (tar_write_header(f, path, '0', st->st_mode, st->st_size, st->st_mtime, NULL) != 0)
        return 1;

    in = fopen(path, "rb");

    if (!in) {
        fprintf(stderr, "tar: %s: %s\n", path, strerror(errno));
        return 1;
    }

    while (remaining > 0) {
        size_t want = remaining < (off_t)sizeof(buf) ? (size_t)remaining : sizeof(buf);
        size_t n = fread(buf, 1, want, in);

        if (n == 0)
            break;

        if (fwrite(buf, 1, n, f) != n) {
            fprintf(stderr, "tar: write error\n");
            fclose(in);
            return 1;
        }

        remaining -= (off_t)n;
    }

    fclose(in);

    return tar_write_padding(f, st->st_size);
}

static int tar_add_symlink(FILE *f, const char *path, const struct stat *st)
{
    char target[PATH_MAX];
    ssize_t n = readlink(path, target, sizeof(target) - 1);

    if (n < 0) {
        fprintf(stderr, "tar: %s: %s\n", path, strerror(errno));
        return 1;
    }

    target[n] = '\0';

    /* No file data or padding for a symlink entry - the target lives in
       the header's own linkname field, not the archive body. */
    return tar_write_header(f, path, '2', st->st_mode, 0, st->st_mtime, target);
}

static int tar_add_dir(FILE *f, const char *path, const struct stat *st)
{
    DIR *dir;
    struct dirent *de;
    int rc = 0;

    if (tar_write_header(f, path, '5', st->st_mode, 0, st->st_mtime, NULL) != 0)
        return 1;

    dir = opendir(path);

    if (!dir) {
        fprintf(stderr, "tar: %s: %s\n", path, strerror(errno));
        return 1;
    }

    while ((de = readdir(dir)) != NULL) {
        char child[PATH_MAX];
        int n;

        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
            continue;

        n = snprintf(child, sizeof(child), "%s/%s", path, de->d_name);

        if (n < 0 || (size_t)n >= sizeof(child)) {
            fprintf(stderr, "tar: path too long: %s/%s\n", path, de->d_name);
            rc = 1;
            continue;
        }

        if (tar_add_path(f, child) != 0)
            rc = 1;
    }

    closedir(dir);
    return rc;
}

static int tar_add_path(FILE *f, const char *path)
{
    struct stat st;

    if (lstat(path, &st) != 0) {
        fprintf(stderr, "tar: %s: %s\n", path, strerror(errno));
        return 1;
    }

    if (S_ISDIR(st.st_mode))
        return tar_add_dir(f, path, &st);

    if (S_ISREG(st.st_mode))
        return tar_add_file(f, path, &st);

    if (S_ISLNK(st.st_mode))
        return tar_add_symlink(f, path, &st);

    fprintf(stderr, "tar: %s: not a regular file, directory, or symlink, skipping\n", path);
    return 1;
}

/* -z support shells out to the "gzip" binary this project already builds
   and verifies separately, via fork()/pipe()/execlp() - not popen() (which
   would build a shell command line from the archive path, an avoidable
   command-injection surface) and not a vendored zlib (which would
   duplicate a decompressor this project already ships). execlp() passes
   the archive path as a real argv element, so a path containing shell
   metacharacters is never interpreted by anything. Resolved via PATH,
   same as any other on-device command - DEFAULT_ROOT_PATH already puts
   /data/bin first (see docs/device_layout.md). */

/* Spawns "gzip -dc [archive]" and returns a FILE* reading its decompressed
   stdout. archive == NULL means "-f -": the child inherits nshbox's own
   stdin instead of being given a filename, so it decompresses whatever is
   piped into nshbox itself. *out_pid receives the child's pid, to be
   passed to tar_gzip_close() once the caller is done reading. Returns
   NULL (nothing to wait for) on failure to even fork. */
static FILE *tar_gzip_spawn_reader(const char *archive, pid_t *out_pid)
{
    int pipefd[2];
    pid_t pid;

    if (pipe(pipefd) != 0) {
        fprintf(stderr, "tar: pipe: %s\n", strerror(errno));
        return NULL;
    }

    pid = fork();

    if (pid < 0) {
        fprintf(stderr, "tar: fork: %s\n", strerror(errno));
        close(pipefd[0]);
        close(pipefd[1]);
        return NULL;
    }

    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);

        if (archive)
            execlp("gzip", "gzip", "-dc", archive, (char *)NULL);
        else
            execlp("gzip", "gzip", "-dc", (char *)NULL);

        fprintf(stderr, "tar: gzip: %s\n", strerror(errno));
        _exit(127);
    }

    close(pipefd[1]);
    *out_pid = pid;
    return fdopen(pipefd[0], "rb");
}

/* Spawns "gzip -c" as a child that reads tar blocks from a pipe (the
   returned FILE*, write end) and writes compressed output to "out" (a
   FILE* the caller already has open - either stdout or a real destination
   file, dup2'd onto the child's own stdout before exec). *out_pid receives
   the child's pid. Returns NULL on failure to even fork. */
static FILE *tar_gzip_spawn_writer(FILE *out, pid_t *out_pid)
{
    int pipefd[2];
    pid_t pid;

    if (pipe(pipefd) != 0) {
        fprintf(stderr, "tar: pipe: %s\n", strerror(errno));
        return NULL;
    }

    pid = fork();

    if (pid < 0) {
        fprintf(stderr, "tar: fork: %s\n", strerror(errno));
        close(pipefd[0]);
        close(pipefd[1]);
        return NULL;
    }

    if (pid == 0) {
        close(pipefd[1]);
        dup2(pipefd[0], STDIN_FILENO);
        close(pipefd[0]);
        dup2(fileno(out), STDOUT_FILENO);

        execlp("gzip", "gzip", "-c", (char *)NULL);

        fprintf(stderr, "tar: gzip: %s\n", strerror(errno));
        _exit(127);
    }

    close(pipefd[0]);
    *out_pid = pid;
    return fdopen(pipefd[1], "wb");
}

/* Closes the pipe end returned by either spawn function above and waits
   for the gzip child, reporting a clear error if it did not exit
   successfully - a missing or failing gzip must never look like a
   silently truncated or empty archive. */
static int tar_gzip_close(FILE *pipe_file, pid_t pid)
{
    int status = 0;

    fclose(pipe_file);

    if (waitpid(pid, &status, 0) < 0) {
        fprintf(stderr, "tar: gzip: waitpid: %s\n", strerror(errno));
        return 1;
    }

    if (!WIFEXITED(status)) {
        fprintf(stderr, "tar: gzip: process did not exit normally\n");
        return 1;
    }

    /* 127 is this project's own spawn_reader()/spawn_writer() sentinel
       for "execlp() itself failed" (the child _exit(127)s after printing
       its own "tar: gzip: <reason>" - typically ENOENT, gzip not found in
       PATH at all). Any OTHER non-zero status means gzip was found and
       ran, but exited unhappy for its own reason (a missing/corrupt
       archive, for instance) - it will already have printed exactly why
       to stderr itself, so repeating "is gzip installed?" here would be
       actively misleading rather than helpful. */
    if (WEXITSTATUS(status) == 127) {
        fprintf(stderr, "tar: gzip: not found in PATH\n");
        return 1;
    }

    if (WEXITSTATUS(status) != 0) {
        fprintf(stderr, "tar: gzip exited with status %d (see its own message above)\n", WEXITSTATUS(status));
        return 1;
    }

    return 0;
}

static int tar_create(const char *archive, const char *chdir_to, char **paths, int npaths,
                       int use_gzip)
{
    FILE *f;
    FILE *out;
    pid_t gzip_pid = 0;
    unsigned char zero[TAR_BLOCK_SIZE];
    int i;
    int rc = 0;

    if (npaths == 0) {
        fprintf(stderr, "tar: no files specified for -c\n");
        return 2;
    }

    /* "-f -" means stdout, the standard tar convention - lets this pipe
       straight into "ssh ... nshbox tar -x -f -" with no archive file on
       either end. Opened (or selected) before -C's chdir() so the archive
       path is always resolved against the directory nshbox was invoked
       from, regardless of -C - only the paths being added move. */
    if (strcmp(archive, "-") == 0) {
        f = stdout;
    } else {
        f = fopen(archive, "wb");

        if (!f) {
            fprintf(stderr, "tar: %s: %s\n", archive, strerror(errno));
            return 1;
        }
    }

    /* With -z, tar blocks go into a pipe to a forked "gzip -c" child
       instead of straight to f; the child's own stdout is dup2'd onto f
       before exec (see tar_gzip_spawn_writer()), so f can be released
       here in the parent once the child holds its own reference to it. */
    if (use_gzip) {
        out = tar_gzip_spawn_writer(f, &gzip_pid);

        if (!out) {
            if (f != stdout)
                fclose(f);
            return 1;
        }

        if (f != stdout)
            fclose(f);
    } else {
        out = f;
    }

    if (chdir_to && chdir(chdir_to) != 0) {
        fprintf(stderr, "tar: -C %s: %s\n", chdir_to, strerror(errno));

        if (use_gzip)
            tar_gzip_close(out, gzip_pid);
        else if (f != stdout)
            fclose(f);

        return 1;
    }

    for (i = 0; i < npaths; i++) {
        if (tar_add_path(out, paths[i]) != 0)
            rc = 1;
    }

    memset(zero, 0, sizeof(zero));
    fwrite(zero, 1, sizeof(zero), out);
    fwrite(zero, 1, sizeof(zero), out);   /* two zero blocks mark end of archive */

    if (use_gzip) {
        if (tar_gzip_close(out, gzip_pid) != 0)
            rc = 1;
    } else if (f == stdout) {
        if (fflush(f) != 0) {
            fprintf(stderr, "tar: stdout: %s\n", strerror(errno));
            rc = 1;
        }
    } else if (fclose(f) != 0) {
        fprintf(stderr, "tar: %s: %s\n", archive, strerror(errno));
        rc = 1;
    }

    return rc;
}

static int tar_mkdir_p(const char *path)
{
    char buf[PATH_MAX];
    char *p;
    size_t len = strlen(path);

    if (len == 0)
        return 0;

    if (len >= sizeof(buf)) {
        fprintf(stderr, "tar: path too long: %s\n", path);
        return 1;
    }

    memcpy(buf, path, len + 1);

    for (p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';

            if (mkdir(buf, 0755) != 0 && errno != EEXIST) {
                fprintf(stderr, "tar: mkdir %s: %s\n", buf, strerror(errno));
                return 1;
            }

            *p = '/';
        }
    }

    if (mkdir(buf, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "tar: mkdir %s: %s\n", buf, strerror(errno));
        return 1;
    }

    return 0;
}

static int tar_ensure_parent_dir(const char *path)
{
    char buf[PATH_MAX];
    char *slash;
    size_t len = strlen(path);

    if (len >= sizeof(buf)) {
        fprintf(stderr, "tar: path too long: %s\n", path);
        return 1;
    }

    memcpy(buf, path, len + 1);
    slash = strrchr(buf, '/');

    if (!slash)
        return 0;

    *slash = '\0';

    return tar_mkdir_p(buf);
}

/* Reads and discards size bytes plus its padding, rather than fseek()ing
   past them - "-f -" (see tar_extract()) means stdin, which may well be a
   pipe (the whole point: "ssh ... | nshbox tar -x -f -"), and fseek()
   does not work on a pipe. Works identically for a regular file too, so
   there is no need for two code paths. */
static int tar_skip_entry_data(FILE *f, unsigned long size)
{
    unsigned char buf[TAR_BLOCK_SIZE];
    size_t rem = (size_t)(size % TAR_BLOCK_SIZE);
    unsigned long total = size + (rem ? (TAR_BLOCK_SIZE - rem) : 0);

    while (total > 0) {
        size_t want = total < sizeof(buf) ? (size_t)total : sizeof(buf);
        size_t got = fread(buf, 1, want, f);

        if (got == 0) {
            fprintf(stderr, "tar: unexpected end of archive\n");
            return 1;
        }

        total -= got;
    }

    return 0;
}

/* list_only: -t. Shares the header/checksum-verify loop with -x, but
   never creates a directory or writes a file - just prints each entry's
   name and skips past its data. -C is meaningless here (nothing gets
   written), so it is not applied when list_only is set. names/name_count:
   when name_count > 0, only entries whose name exactly matches one of
   these are extracted/listed - everything else is skipped past without
   being written or printed. name_count == 0 means "everything," the
   original behavior - so this is purely additive for existing callers. */
static int tar_extract(const char *archive, const char *chdir_to, int list_only,
                        int use_gzip, char **names, int name_count)
{
    FILE *f;
    pid_t gzip_pid = 0;
    unsigned char hdr[TAR_BLOCK_SIZE];
    int rc = 0;
    int *found;

    /* "-f -" means stdin, the standard tar convention - see tar_create()
       for the matching stdout case. With -z, archive == "-" makes the
       gzip child inherit nshbox's own stdin instead (see
       tar_gzip_spawn_reader()), rather than nshbox itself reading stdin
       directly. */
    if (use_gzip) {
        f = tar_gzip_spawn_reader(strcmp(archive, "-") == 0 ? NULL : archive, &gzip_pid);

        if (!f)
            return 1;
    } else if (strcmp(archive, "-") == 0) {
        f = stdin;
    } else {
        f = fopen(archive, "rb");

        if (!f) {
            fprintf(stderr, "tar: %s: %s\n", archive, strerror(errno));
            return 1;
        }
    }

    if (chdir_to && !list_only) {
        if (tar_mkdir_p(chdir_to) != 0 || chdir(chdir_to) != 0) {
            fprintf(stderr, "tar: -C %s: %s\n", chdir_to, strerror(errno));

            if (use_gzip)
                tar_gzip_close(f, gzip_pid);
            else if (f != stdin)
                fclose(f);

            return 1;
        }
    }

    /* Tracks which requested names (if any) were actually seen in the
       archive - matching real GNU tar's own behavior of erroring on a
       name that was never found, rather than silently "succeeding" at
       extracting nothing at all. Found the hard way (2026-09-13):
       runtime/on-demand-run.sh invoked directly (instead of through one
       of its per-tool symlinks) asked for a member matching its own
       filename, which obviously never matches anything real, and the
       resulting empty-but-"successful" extraction turned into a
       confusing downstream "chmod: No such file or directory" instead of
       a clear tar-level error. */
    found = (name_count > 0) ? calloc((size_t)name_count, sizeof(*found)) : NULL;

    if (name_count > 0 && !found) {
        fprintf(stderr, "tar: out of memory\n");

        if (use_gzip)
            tar_gzip_close(f, gzip_pid);
        else if (f != stdin)
            fclose(f);

        return 1;
    }

    for (;;) {
        size_t n = fread(hdr, 1, TAR_BLOCK_SIZE, f);
        unsigned char check_copy[TAR_BLOCK_SIZE];
        char name[TAR_NAME_LEN + 1];
        unsigned long mode_val, size_val, sum_expected, sum_actual;
        char typeflag;
        int is_dir;
        size_t i;

        if (n == 0)
            break;

        if (n != TAR_BLOCK_SIZE) {
            fprintf(stderr, "tar: %s: truncated header\n", archive);
            rc = 1;
            break;
        }

        {
            int all_zero = 1;

            for (i = 0; i < TAR_BLOCK_SIZE; i++) {
                if (hdr[i] != 0) {
                    all_zero = 0;
                    break;
                }
            }

            if (all_zero)
                break;   /* end-of-archive marker */
        }

        sum_expected = tar_read_octal(hdr + TAR_OFF_CHKSUM, 8);
        memcpy(check_copy, hdr, TAR_BLOCK_SIZE);
        memset(check_copy + TAR_OFF_CHKSUM, ' ', 8);
        sum_actual = 0;

        for (i = 0; i < TAR_BLOCK_SIZE; i++)
            sum_actual += check_copy[i];

        if (sum_actual != sum_expected) {
            fprintf(stderr, "tar: %s: corrupt header (checksum mismatch)\n", archive);
            rc = 1;
            break;
        }

        memcpy(name, hdr + TAR_OFF_NAME, TAR_NAME_LEN);
        name[TAR_NAME_LEN] = '\0';

        /* Defense in depth, matching GNU tar's own default ("Removing
           leading '/' from member names" unless -P/--absolute-names is
           given): tar_write_header() no longer stores a leading "/" in
           anything nshbox itself creates, but an archive from elsewhere
           (real GNU tar with -P, or one created before this fix) could
           still have one. Extracting such a name verbatim would write
           straight to that absolute path regardless of -C or the current
           directory - exactly the surprise this project hit archiving
           /etc directly. */
        {
            char *stripped = name;

            while (*stripped == '/')
                stripped++;

            if (stripped != name)
                memmove(name, stripped, strlen(stripped) + 1);
        }

        mode_val = tar_read_octal(hdr + TAR_OFF_MODE, 8);
        size_val = tar_read_octal(hdr + TAR_OFF_SIZE, 12);
        typeflag = (char)hdr[TAR_OFF_TYPEFLAG];
        is_dir = (typeflag == '5') || (name[0] && name[strlen(name) - 1] == '/');

        if (name_count > 0) {
            int wanted = 0;

            for (i = 0; i < (size_t)name_count; i++) {
                if (strcmp(name, names[i]) == 0) {
                    wanted = 1;
                    found[i] = 1;
                    break;
                }
            }

            if (!wanted) {
                /* Directory and symlink headers carry no body to skip -
                   only a regular file's data (plus its padding) needs to
                   be read past via tar_skip_entry_data(). */
                if (!is_dir && typeflag != '2' && tar_skip_entry_data(f, size_val) != 0) {
                    rc = 1;
                    break;
                }

                continue;
            }
        }

        /* Not for list_only - "-t" already prints every entry's name to
         * stdout as its own listing; -v there would just repeat it. */
        if (tar_verbose && !list_only)
            fprintf(stderr, "%s\n", name);

        if (is_dir) {
            if (list_only)
                printf("%s\n", name);
            else if (tar_mkdir_p(name) != 0)
                rc = 1;
            continue;
        }

        if (typeflag == '2') {
            char linkname[TAR_LINKNAME_LEN + 1];

            memcpy(linkname, hdr + TAR_OFF_LINKNAME, TAR_LINKNAME_LEN);
            linkname[TAR_LINKNAME_LEN] = '\0';

            if (list_only) {
                printf("%s -> %s\n", name, linkname);
                continue;
            }

            /* Matches real tar's own overwrite behavior - unlink()
               first rather than letting symlink() fail with EEXIST if
               this entry is being re-extracted over a previous run. */
            unlink(name);

            if (symlink(linkname, name) != 0) {
                fprintf(stderr, "tar: %s -> %s: %s\n", name, linkname, strerror(errno));
                rc = 1;
            }

            continue;
        }

        if (typeflag != '0' && typeflag != '\0') {
            fprintf(stderr, "tar: %s: unsupported entry type '%c', skipping\n", name, typeflag);
            if (tar_skip_entry_data(f, size_val) != 0) {
                rc = 1;
                break;
            }
            continue;
        }

        if (list_only) {
            printf("%s\n", name);
            if (tar_skip_entry_data(f, size_val) != 0) {
                rc = 1;
                break;
            }
            continue;
        }

        {
            FILE *out;
            unsigned char buf[TAR_BLOCK_SIZE];
            unsigned long remaining = size_val;

            if (tar_ensure_parent_dir(name) != 0) {
                rc = 1;
                if (tar_skip_entry_data(f, size_val) != 0)
                    break;
                continue;
            }

            out = fopen(name, "wb");

            if (!out) {
                fprintf(stderr, "tar: %s: %s\n", name, strerror(errno));
                rc = 1;
                if (tar_skip_entry_data(f, size_val) != 0)
                    break;
                continue;
            }

            while (remaining > 0) {
                size_t want = remaining < sizeof(buf) ? (size_t)remaining : sizeof(buf);
                size_t got = fread(buf, 1, want, f);

                if (got == 0)
                    break;

                fwrite(buf, 1, got, out);
                remaining -= got;
            }

            fclose(out);
            chmod(name, (mode_t)(mode_val & 0777));

            {
                size_t rem = (size_t)(size_val % TAR_BLOCK_SIZE);
                unsigned char pad[TAR_BLOCK_SIZE];

                if (rem != 0 && fread(pad, 1, TAR_BLOCK_SIZE - rem, f) != TAR_BLOCK_SIZE - rem) {
                    fprintf(stderr, "tar: unexpected end of archive\n");
                    rc = 1;
                    break;
                }
            }
        }
    }

    if (found) {
        size_t i;

        for (i = 0; i < (size_t)name_count; i++) {
            if (!found[i]) {
                fprintf(stderr, "tar: %s: not found in archive\n", names[i]);
                rc = 1;
            }
        }

        free(found);
    }

    if (use_gzip) {
        /* Real GNU tar (used to build install_on_demand.sh's archive on
           the host) pads its output to a full record/blocking-factor
           boundary by default - real trailing data can follow the
           logical two-zero-block end-of-archive marker the loop above
           already stopped reading at. Draining whatever gzip still has
           to write, rather than closing the pipe the moment the logical
           archive ends, avoids gzip receiving SIGPIPE mid-write of that
           trailing padding - confirmed on a real device (2026-09-13):
           "tar: gzip: process did not exit normally", intermittently,
           depending on exactly how much padding was still buffered at
           close time (not reproducible on a fast host - the race window
           is real but narrow there; the slower target device hits it
           far more easily). */
        unsigned char discard[4096];

        while (fread(discard, 1, sizeof(discard), f) > 0)
            ;

        if (tar_gzip_close(f, gzip_pid) != 0)
            rc = 1;
    } else if (f != stdin) {
        fclose(f);
    }

    return rc;
}

static int cmd_tar(int argc, char **argv)
{
    static const char usage_msg[] =
        "Usage: nshbox tar -c|-x|-t[zv] -f archive [-C dir] [path ...]\n"
        "       archive may be \"-\" for stdin (-x/-t) or stdout (-c)\n"
        "       -z (or a .tar.gz/.tgz/.taz archive name) gzip-compresses\n"
        "       or decompresses via the gzip binary found in PATH\n"
        "       -v prints each file name to stderr as it is added or\n"
        "       extracted (no effect combined with -t, which already\n"
        "       prints names as its listing)\n"
        "       for -x/-t, trailing path arguments extract/list only\n"
        "       those members instead of the whole archive\n";

    int mode = 0;   /* 'c', 'x', or 't' */
    int use_gzip = 0;
    const char *archive = NULL;
    const char *chdir_to = NULL;
    int argi = 1;

    /* Reset here, not just at file scope - nshbox is single-command-per-
     * process today, but resetting defensively costs nothing and avoids
     * this static silently leaking state if that ever changes. */
    tar_verbose = 0;

    while (argi < argc && argv[argi][0] == '-' && argv[argi][1]) {
        const char *p = argv[argi] + 1;

        if (!strcmp(argv[argi], "--")) {
            argi++;
            break;
        }

        while (*p) {
            if (*p == 'c' || *p == 'x' || *p == 't') {
                if (mode) {
                    fprintf(stderr, "tar: -c, -x, and -t are mutually exclusive\n");
                    return 2;
                }
                mode = *p;
                p++;
            } else if (*p == 'z') {
                use_gzip = 1;
                p++;
            } else if (*p == 'v') {
                tar_verbose = 1;
                p++;
            } else if (*p == 'f') {
                p++;
                if (*p) {
                    archive = p;
                    p += strlen(p);
                } else {
                    if (++argi >= argc) {
                        fprintf(stderr, "%s", usage_msg);
                        return 2;
                    }
                    archive = argv[argi];
                }
            } else if (*p == 'C') {
                p++;
                if (*p) {
                    chdir_to = p;
                    p += strlen(p);
                } else {
                    if (++argi >= argc) {
                        fprintf(stderr, "%s", usage_msg);
                        return 2;
                    }
                    chdir_to = argv[argi];
                }
            } else {
                fprintf(stderr, "%s", usage_msg);
                return 2;
            }
        }
        argi++;
    }

    if (!mode || !archive) {
        fprintf(stderr, "%s", usage_msg);
        return 2;
    }

    /* .tar.gz/.tgz/.taz auto-detection - a convenience on top of the
       explicit -z flag, not a substitute for it. "-" (stdin/stdout) is
       never auto-detected: there is no name to inspect. */
    if (!use_gzip && strcmp(archive, "-") != 0) {
        size_t len = strlen(archive);

        if ((len > 3 && strcmp(archive + len - 3, ".gz") == 0) ||
            (len > 4 && strcmp(archive + len - 4, ".tgz") == 0) ||
            (len > 4 && strcmp(archive + len - 4, ".taz") == 0)) {
            use_gzip = 1;
        }
    }

    if (mode == 'c')
        return tar_create(archive, chdir_to, argv + argi, argc - argi, use_gzip);

    return tar_extract(archive, chdir_to, mode == 't', use_gzip, argv + argi, argc - argi);
}


/* ------------------------------------------------------------------ */
/* sha256sum / sha1sum / sha512sum / md5sum                           */
/* ------------------------------------------------------------------ */

/* --json: one array of {"file","algorithm","digest"} objects, one per
 * file actually hashed. *count is how many entries have been emitted so
 * far (drives the comma between them); ignored in plain text mode. A file
 * that cannot be read gets its usual message on stderr and a non-zero
 * exit, and no entry - same as text mode, which prints nothing on stdout
 * for it either, so "digest" is always a real digest, never a placeholder. */
static int hash_stream(FILE *f, const char *display_name, const EVP_MD *md,
                       const char *algo, int json, int *count)
{
    EVP_MD_CTX *ctx;
    unsigned char buf[65536];
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int digest_len;
    size_t n;
    unsigned int i;

    ctx = EVP_MD_CTX_new();

    if (ctx == NULL) {
        fprintf(stderr, "nshbox: out of memory\n");
        return 1;
    }

    if (EVP_DigestInit_ex(ctx, md, NULL) != 1) {
        fprintf(stderr, "nshbox: EVP_DigestInit_ex failed\n");
        EVP_MD_CTX_free(ctx);
        return 1;
    }

    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        if (EVP_DigestUpdate(ctx, buf, n) != 1) {
            fprintf(stderr, "nshbox: EVP_DigestUpdate failed\n");
            EVP_MD_CTX_free(ctx);
            return 1;
        }
    }

    if (ferror(f)) {
        perror(display_name);
        EVP_MD_CTX_free(ctx);
        return 1;
    }

    if (EVP_DigestFinal_ex(ctx, digest, &digest_len) != 1) {
        fprintf(stderr, "nshbox: EVP_DigestFinal_ex failed\n");
        EVP_MD_CTX_free(ctx);
        return 1;
    }

    EVP_MD_CTX_free(ctx);

    if (json) {
        if (*count > 0)
            putchar(',');
        (*count)++;

        fputs("{\"file\":", stdout);
        json_print_string(display_name);
        printf(",\"algorithm\":\"%s\",\"digest\":\"", algo);

        for (i = 0; i < digest_len; i++)
            printf("%02x", digest[i]);

        fputs("\"}", stdout);
        return 0;
    }

    for (i = 0; i < digest_len; i++)
        printf("%02x", digest[i]);

    printf("  %s\n", display_name);
    return 0;
}

static int hash_main(int argc, char **argv, const EVP_MD *md, const char *algo)
{
    int rc = 0;
    int json = 0;
    int count = 0;
    int files = 0;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0)
            json = 1;
        else
            files++;
    }

    if (json)
        putchar('[');

    if (files == 0) {
        rc = hash_stream(stdin, "-", md, algo, json, &count);
    } else {
        for (i = 1; i < argc; i++) {
            FILE *f;

            if (strcmp(argv[i], "--json") == 0)
                continue;

            if (strcmp(argv[i], "-") == 0) {
                if (hash_stream(stdin, "-", md, algo, json, &count) != 0)
                    rc = 1;
                continue;
            }

            f = fopen(argv[i], "rb");

            if (f == NULL) {
                perror(argv[i]);
                rc = 1;
                continue;
            }

            if (hash_stream(f, argv[i], md, algo, json, &count) != 0)
                rc = 1;

            fclose(f);
        }
    }

    if (json)
        fputs("]\n", stdout);

    return rc;
}

static int cmd_sha256sum(int argc, char **argv)
{
    return hash_main(argc, argv, EVP_sha256(), "sha256");
}

static int cmd_sha1sum(int argc, char **argv)
{
    return hash_main(argc, argv, EVP_sha1(), "sha1");
}

static int cmd_sha384sum(int argc, char **argv)
{
    return hash_main(argc, argv, EVP_sha384(), "sha384");
}

static int cmd_sha512sum(int argc, char **argv)
{
    return hash_main(argc, argv, EVP_sha512(), "sha512");
}

static int cmd_md5sum(int argc, char **argv)
{
    return hash_main(argc, argv, EVP_md5(), "md5");
}

/*
 * No SHA3 commands here - EVP_sha3_*() needs OpenSSL >= 1.1.1, and the
 * TC002's real /lib/libcrypto.so.1.1 is older than that (confirmed
 * on-device: linking SHA3 in made the whole nshbox binary refuse to
 * start with "version `OPENSSL_1_1_1' not found", not just the SHA3
 * commands - see nshbox/README.md). Every command above uses OpenSSL
 * 1.1.0-or-earlier API surface, which the device's library does have.
 */


/* ------------------------------------------------------------------ */
/* base64                                                             */
/* ------------------------------------------------------------------ */

static const char base64_std_alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const char base64_url_alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static int base64_encode_stream(FILE *in, FILE *out, long wrap, const char *alphabet)
{
    unsigned char in3[3];
    size_t n;
    long col = 0;

    while ((n = fread(in3, 1, 3, in)) > 0) {
        unsigned char out4[4];
        unsigned int triple = (unsigned int)in3[0] << 16;
        int i;

        if (n > 1)
            triple |= (unsigned int)in3[1] << 8;
        if (n > 2)
            triple |= (unsigned int)in3[2];

        out4[0] = (unsigned char)alphabet[(triple >> 18) & 0x3f];
        out4[1] = (unsigned char)alphabet[(triple >> 12) & 0x3f];
        out4[2] = (n > 1) ? (unsigned char)alphabet[(triple >> 6) & 0x3f] : (unsigned char)'=';
        out4[3] = (n > 2) ? (unsigned char)alphabet[triple & 0x3f] : (unsigned char)'=';

        for (i = 0; i < 4; i++) {
            putc(out4[i], out);
            col++;
            if (wrap > 0 && col == wrap) {
                putc('\n', out);
                col = 0;
            }
        }
    }

    if (ferror(in))
        return 1;

    if (wrap > 0 && col != 0)
        putc('\n', out);

    return 0;
}

static int base64_decode_value(unsigned char c, int url_safe)
{
    if (c >= 'A' && c <= 'Z')
        return c - 'A';
    if (c >= 'a' && c <= 'z')
        return c - 'a' + 26;
    if (c >= '0' && c <= '9')
        return c - '0' + 52;

    if (url_safe) {
        if (c == '-') return 62;
        if (c == '_') return 63;
    } else {
        if (c == '+') return 62;
        if (c == '/') return 63;
    }

    return -1;
}

static void base64_emit_group(const unsigned char group[4], int pad, FILE *out)
{
    unsigned int triple = ((unsigned int)group[0] << 18) |
                           ((unsigned int)group[1] << 12) |
                           ((unsigned int)group[2] << 6) |
                           (unsigned int)group[3];

    putc((int)((triple >> 16) & 0xff), out);
    if (pad < 2)
        putc((int)((triple >> 8) & 0xff), out);
    if (pad < 1)
        putc((int)(triple & 0xff), out);
}

/* Tolerates a final group with no explicit "=" padding at all (2 or 3
 * leftover symbols at EOF) as well as one that does carry it - the former
 * is how base64url is used in practice (JWTs, see cmd_jwt below), and
 * treating both the same way here means jwt_decode_segment() below needs
 * no separate decoder. A lone leftover symbol (count == 1) is never valid
 * in either form. */
static int base64_decode_stream(FILE *in, FILE *out, int url_safe)
{
    unsigned char group[4];
    int count = 0;
    int pad = 0;
    int c;

    while ((c = getc(in)) != EOF) {
        if (c == '\n' || c == '\r')
            continue;

        if (c == '=') {
            group[count++] = 0;
            pad++;
        } else {
            int v = base64_decode_value((unsigned char)c, url_safe);

            if (v < 0) {
                fprintf(stderr, "base64: invalid input\n");
                return 1;
            }
            group[count++] = (unsigned char)v;
        }

        if (count == 4) {
            base64_emit_group(group, pad, out);
            count = 0;
            pad = 0;
        }
    }

    if (ferror(in))
        return 1;

    if (count == 1) {
        fprintf(stderr, "base64: invalid input (truncated)\n");
        return 1;
    }

    if (count > 0) {
        pad += (4 - count);
        while (count < 4)
            group[count++] = 0;
        base64_emit_group(group, pad, out);
    }

    return 0;
}

static int cmd_base64(int argc, char **argv)
{
    static const char usage[] = "Usage: nshbox base64 [-d] [-u] [-w cols] [file]\n";
    int decode = 0;
    int url_safe = 0;
    long wrap = 76;
    int argi = 1;
    FILE *in = stdin;
    int rc;

    while (argi < argc && argv[argi][0] == '-' && argv[argi][1]) {
        if (!strcmp(argv[argi], "--")) {
            argi++;
            break;
        } else if (!strcmp(argv[argi], "-d")) {
            decode = 1;
            argi++;
        } else if (!strcmp(argv[argi], "-u")) {
            url_safe = 1;
            argi++;
        } else if (!strncmp(argv[argi], "-w", 2)) {
            /* Accepts both "-w cols" and the attached "-wcols" form (e.g.
             * "-w0") - real base64/basenc accept both via getopt, and
             * "-w0" specifically is the idiom most people actually type
             * for "no wrapping". */
            const char *val = argv[argi][2] ? argv[argi] + 2 : NULL;
            char *end;
            int consumed = 1;

            if (!val) {
                if (argi + 1 >= argc) {
                    fprintf(stderr, "%s", usage);
                    return 2;
                }
                val = argv[argi + 1];
                consumed = 2;
            }

            errno = 0;
            wrap = strtol(val, &end, 10);
            if (errno || *end || wrap < 0) {
                fprintf(stderr, "%s", usage);
                return 2;
            }
            argi += consumed;
        } else {
            fprintf(stderr, "%s", usage);
            return 2;
        }
    }

    if (argi < argc) {
        in = fopen(argv[argi], "rb");
        if (!in) {
            perror(argv[argi]);
            return 1;
        }
        argi++;
    }

    if (argi != argc) {
        fprintf(stderr, "%s", usage);
        if (in != stdin)
            fclose(in);
        return 2;
    }

    if (decode)
        rc = base64_decode_stream(in, stdout, url_safe);
    else
        rc = base64_encode_stream(in, stdout, wrap, url_safe ? base64_url_alphabet : base64_std_alphabet);

    if (in != stdin)
        fclose(in);

    return rc;
}


/* ------------------------------------------------------------------ */
/* jwt                                                                */
/* ------------------------------------------------------------------ */

/* Decodes one '.'-delimited JWT segment (always base64url, see RFC 7519)
 * straight to stdout via fmemopen() + the same base64_decode_stream()
 * used by "base64 -u" - no separate decoder to keep in sync. Does not
 * verify anything: JWT segments are just base64url(JSON), and printing
 * the decoded header/payload here is strictly a read-only convenience
 * for inspecting a token without pasting it into an external site. */
static int jwt_decode_segment(const char *seg, size_t len)
{
    FILE *in;
    int rc;

    in = fmemopen((void *)seg, len, "r");
    if (!in) {
        perror("fmemopen");
        return 1;
    }

    rc = base64_decode_stream(in, stdout, 1);
    fclose(in);
    putchar('\n');
    return rc;
}

static int cmd_jwt(int argc, char **argv)
{
    static const char usage[] = "Usage: nshbox jwt [--all|--header] [token]\n";
    char *line = NULL;
    size_t cap = 0;
    const char *token;
    const char *dot1, *dot2;
    int rc = 0;
    int argi = 1;
    /* Default: payload only - the claims are almost always what someone
     * actually wants to glance at; --header/--all opt into the rest. */
    int show_header = 0;
    int show_payload = 1;

    if (argi < argc && !strcmp(argv[argi], "--all")) {
        show_header = 1;
        argi++;
    } else if (argi < argc && !strcmp(argv[argi], "--header")) {
        show_header = 1;
        show_payload = 0;
        argi++;
    }

    if (argc - argi > 1) {
        fprintf(stderr, "%s", usage);
        return 2;
    }

    if (argi < argc) {
        token = argv[argi];
    } else {
        /* Prefer stdin over an argv token where possible - an argument
         * lands in the process's own /proc/<pid>/cmdline and in "ps"
         * output for as long as this process runs, visible to any other
         * user who can see the process table; stdin does not. */
        ssize_t len = getline(&line, &cap, stdin);

        if (len < 0) {
            free(line);
            fprintf(stderr, "jwt: no input\n");
            return 1;
        }
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        token = line;
    }

    dot1 = strchr(token, '.');
    dot2 = dot1 ? strchr(dot1 + 1, '.') : NULL;

    if (!dot1 || !dot2) {
        fprintf(stderr, "jwt: not a JWT (expected header.payload.signature)\n");
        free(line);
        return 1;
    }

    if (show_header && jwt_decode_segment(token, (size_t)(dot1 - token)) != 0)
        rc = 1;
    if (show_payload && jwt_decode_segment(dot1 + 1, (size_t)(dot2 - dot1 - 1)) != 0)
        rc = 1;

    free(line);
    return rc;
}


/* ------------------------------------------------------------------ */
/* json (pretty-printer)                                              */
/* ------------------------------------------------------------------ */

#define JSON_MAX_DEPTH 256

static void json_print_indent(FILE *out, int depth)
{
    int i;

    for (i = 0; i < depth; i++)
        fputs("  ", out);
}

/* Called just before writing any significant, non-structural token (a
 * string's opening quote, a number/true/false/null character, or a
 * nested '{'/'[') - if nothing has been written inside the innermost
 * open container yet, this writes the newline+indent that goes before
 * its first entry and marks the container non-empty, so its own closing
 * bracket later knows to go on its own line too rather than folding
 * back onto the opener (see the '}'/']' case in json_pretty_print()). */
static void json_before_token(FILE *out, int *need_indent, int depth)
{
    if (depth == 0)
        return;

    if (need_indent[depth - 1]) {
        putc('\n', out);
        json_print_indent(out, depth);
        need_indent[depth - 1] = 0;
    }
}

/* Reformats one JSON document read from "in" into indented, human-
 * readable form written to "out" - a single-pass bracket-tracking
 * reformatter, not a full parser: it does not validate number syntax or
 * string escape correctness, only tracks string boundaries (so a brace
 * or comma inside a string is never mistaken for structure) and
 * container nesting depth. That is enough to correctly pretty-print
 * anything nshbox's own --json commands emit, or any other well-formed
 * JSON piped in from elsewhere - see cmd_json() below, the standalone
 * command this backs. Kept as one shared, reusable function rather than
 * inlined into cmd_json() specifically so a future "--json but pretty"
 * variant of ps/du/find/dig/nslookup/uptime's own --json output could
 * call this same function on their already-built output instead of a
 * second implementation - not wired up yet, see nshbox/README.md.
 * Two spaces per indent level, matching this project's own C source
 * style. Returns 0 on success, 1 if the brackets in the input are
 * unbalanced (missing/extra '}'/']') or nesting exceeds
 * JSON_MAX_DEPTH - either way, whatever was already written stands as
 * a best-effort partial result, not rolled back. */
static int json_pretty_print(FILE *in, FILE *out)
{
    int need_indent[JSON_MAX_DEPTH];
    int depth = 0;
    int in_string = 0;
    int escape = 0;
    int c;

    while ((c = getc(in)) != EOF) {
        if (in_string) {
            putc(c, out);
            if (escape)
                escape = 0;
            else if (c == '\\')
                escape = 1;
            else if (c == '"')
                in_string = 0;
            continue;
        }

        if (isspace(c))
            continue;

        switch (c) {
        case '"':
            json_before_token(out, need_indent, depth);
            putc(c, out);
            in_string = 1;
            break;

        case '{':
        case '[':
            json_before_token(out, need_indent, depth);
            if (depth >= JSON_MAX_DEPTH) {
                fprintf(stderr, "json: nesting too deep (max %d)\n", JSON_MAX_DEPTH);
                return 1;
            }
            putc(c, out);
            need_indent[depth] = 1;
            depth++;
            break;

        case '}':
        case ']':
            if (depth == 0) {
                fprintf(stderr, "json: unmatched '%c'\n", c);
                return 1;
            }
            depth--;
            if (!need_indent[depth]) {
                putc('\n', out);
                json_print_indent(out, depth);
            }
            putc(c, out);
            break;

        case ',':
            putc(c, out);
            if (depth > 0)
                need_indent[depth - 1] = 1;
            break;

        case ':':
            putc(c, out);
            putc(' ', out);
            break;

        default:
            json_before_token(out, need_indent, depth);
            putc(c, out);
            break;
        }
    }

    putc('\n', out);

    if (ferror(in))
        return 1;

    if (depth != 0) {
        fprintf(stderr, "json: unexpected end of input (%d unclosed container(s))\n", depth);
        return 1;
    }

    return 0;
}

static int cmd_json(int argc, char **argv)
{
    static const char usage[] = "Usage: nshbox json [file]\n";
    FILE *in = stdin;
    int rc;

    if (argc > 2) {
        fprintf(stderr, "%s", usage);
        return 2;
    }

    if (argc == 2) {
        in = fopen(argv[1], "r");
        if (!in) {
            perror(argv[1]);
            return 1;
        }
    }

    rc = json_pretty_print(in, stdout);

    if (in != stdin)
        fclose(in);

    return rc;
}


/* ------------------------------------------------------------------ */
/* ldd                                                                */
/* ------------------------------------------------------------------ */

static int cmd_ldd(int argc, char **argv)
{
    static const char linker[] = "/lib/ld-linux-armhf.so.3";
    char **linker_argv;
    int i;

    /* Not its own program - just the dynamic linker's own --list mode,
     * the same trick glibc's own ldd uses under the hood. */
    linker_argv = calloc((size_t)argc + 2, sizeof(*linker_argv));

    if (linker_argv == NULL) {
        perror("calloc");
        return 1;
    }

    linker_argv[0] = (char *)linker;
    linker_argv[1] = (char *)"--list";

    for (i = 1; i < argc; i++)
        linker_argv[i + 1] = argv[i];

    execv(linker, linker_argv);
    perror(linker);
    free(linker_argv);
    return 1;
}


static int cmd_install(int argc, char **argv);

static const command_t commands[] = {
    { "sysinfo",  cmd_sysinfo,  "Show system/CPU/memory information [--json]" },
    { "ps",       cmd_ps,       "Show processes [--json]" },
    { "pstree",   cmd_pstree,   "Show process tree, box-drawing by default (-a plain) [pid]" },
    { "free",     cmd_free,     "Show memory information" },
    { "vmstat",   cmd_vmstat,   "Show procs/memory/swap/io/cpu stats [delay [count]]" },
    { "iostat",   cmd_iostat,   "Show per-device disk transfer/await/util stats [delay [count]]" },
    { "top",      cmd_top,      "List processes by CPU or memory usage (-m, -l lines) [delay [count]]" },
    { "netstat",  cmd_netstat,  "Show TCP sockets (-l = listeners) [--json]" },
    { "readlink", cmd_readlink, "Display link target (-f = canonical path)" },
    { "realpath", cmd_realpath, "Print resolved absolute path" },
    { "dirname",  cmd_dirname,  "Strip last path component" },
    { "grep",     cmd_grep,     "Search text (-i -n -v -q -c -E -r recursive -l files-with-matches)" },
    { "strings",  cmd_strings,  "Print strings (-n min)" },
    { "hexdump",  cmd_hexdump,  "Hex/ASCII dump" },
    { "file",     cmd_file,     "Identify file type (-b brief, -L follow links)" },
    { "stat",     cmd_stat,     "Show file information [--json]" },
    { "head",     cmd_head,     "Show first lines (-n lines)" },
    { "tail",     cmd_tail,     "Show last lines (-n lines)" },
    { "wc",       cmd_wc,       "Count lines/words/bytes (-lwc)" },
    { "sort",     cmd_sort,     "Sort lines (-r reverse, -n numeric, -u unique)" },
    { "tee",      cmd_tee,      "Copy stdin to stdout/files (-a)" },
    { "which",    cmd_which,    "Locate command in PATH" },
    { "clear",    cmd_clear,    "Clear terminal" },
    { "sleep",    cmd_sleep,    "Sleep for SECONDS (fractional allowed)" },
    { "uptime",   cmd_uptime,   "Show time/uptime/load average [--json]" },
    { "du",       cmd_du,       "Show disk usage (-h -s -b) [--json]" },
    { "find",     cmd_find,     "Search a directory tree (-name -type -maxdepth) [--json]" },
    { "tree",     cmd_tree,     "Show a directory tree, box-drawing style [-L level] [path]" },
    { "tar",      cmd_tar,      "Create/extract/list a ustar archive (-cxt[zv] -f archive [-C dir] [path ...])" },
    { "iotest",   cmd_iotest,   "Sequential read/write throughput test (-w file size|-t s|-n N [cap] | -r file)" },
    { "sha256sum",cmd_sha256sum,"Print SHA-256 checksums [--json]" },
    { "sha1sum",  cmd_sha1sum,  "Print SHA-1 checksums [--json]" },
    { "sha384sum",cmd_sha384sum,"Print SHA-384 checksums [--json]" },
    { "sha512sum",cmd_sha512sum,"Print SHA-512 checksums [--json]" },
    { "md5sum",   cmd_md5sum,   "Print MD5 checksums [--json]" },
    { "base64",   cmd_base64,   "Base64 encode/decode (-d decode, -u URL-safe alphabet, -w cols wrap, 0 = no wrap) [file]" },
    { "jwt",      cmd_jwt,      "Decode a JWT's payload (--header for header, --all for both) - no signature verification [token]" },
    { "json",     cmd_json,     "Pretty-print JSON, 2-space indent [file]" },
    { "ldd",      cmd_ldd,      "List a binary's shared library dependencies" },
    { "hostname", cmd_hostname, "Print the system hostname (-f fully-qualified)" },
    { "dig",      cmd_dig,      "DNS lookup [--json] [name] [A|CNAME|MX|TXT]" },
    { "nslookup", cmd_nslookup, "DNS lookup [--json] [-type=A|CNAME|MX|TXT] name" },
    { "install",  cmd_install,  "Create applet symlinks in nshbox directory (-f)" },
    { NULL,       NULL,         NULL }
};


/* ------------------------------------------------------------------ */
/* install                                                            */
/* ------------------------------------------------------------------ */

static int cmd_install(int argc, char **argv)
{
    char exe[PATH_MAX];
    char dir[PATH_MAX];
    char *base;
    ssize_t len;
    int force = 0;
    int quiet = 0;
    int rc = 0;
    int i;
    const command_t *cmd;

    /* -q added after a real complaint (2026-09-13): this runs on every
     * single deploy AND every device boot (see runtime/init.sh and
     * install/install_tools.sh's post-install hook - both legitimately
     * need to re-run this defensively, but printing 30+ unchanged "[OK]"
     * lines every single time is pure noise). Quiet suppresses only
     * "[OK]" (nothing to report); "[NEW]"/"[SKIP]" - actual signal - are
     * never suppressed.
     */
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-f") == 0)
            force = 1;
        else if (strcmp(argv[i], "-q") == 0)
            quiet = 1;
        else if (strcmp(argv[i], "-fq") == 0 || strcmp(argv[i], "-qf") == 0)
            force = quiet = 1;
        else {
            fprintf(stderr, "Usage: nshbox install [-f] [-q]\n");
            return 1;
        }
    }

    len = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (len < 0) {
        perror("/proc/self/exe");
        return 1;
    }
    exe[len] = '\0';

    if (strlen(exe) >= sizeof(dir)) {
        fprintf(stderr, "nshbox: executable path too long\n");
        return 1;
    }
    strcpy(dir, exe);

    base = strrchr(dir, '/');
    if (!base) {
        fprintf(stderr, "nshbox: cannot determine executable directory\n");
        return 1;
    }
    *base++ = '\0';

    /* The symlinks live beside nshbox, so a relative target is enough. */
    for (cmd = commands; cmd->name; cmd++) {
        char linkpath[PATH_MAX];
        struct stat st;

        if (strcmp(cmd->name, "install") == 0)
            continue;

        if (snprintf(linkpath, sizeof(linkpath), "%s/%s", dir, cmd->name) >=
                (int)sizeof(linkpath)) {
            fprintf(stderr, "nshbox: path too long: %s/%s\n", dir, cmd->name);
            rc = 1;
            continue;
        }

        if (lstat(linkpath, &st) == 0) {
            if (S_ISLNK(st.st_mode)) {
                char target[PATH_MAX];
                ssize_t n = readlink(linkpath, target, sizeof(target) - 1);

                if (n >= 0) {
                    target[n] = '\0';
                    if (strcmp(target, base) == 0) {
                        if (!quiet)
                            printf("%-7s%-11s\n", "[OK]", cmd->name);
                        continue;
                    }
                }

                if (!force) {
                    printf("%-7s%-11s(existing symlink; use -f)\n", "[SKIP]", cmd->name);
                    continue;
                }

                if (unlink(linkpath) != 0) {
                    perror(linkpath);
                    rc = 1;
                    continue;
                }
            } else {
                printf("%-7s%-11s(existing file)\n", "[SKIP]", cmd->name);
                continue;
            }
        } else if (errno != ENOENT) {
            perror(linkpath);
            rc = 1;
            continue;
        }

        if (symlink(base, linkpath) != 0) {
            perror(linkpath);
            rc = 1;
            continue;
        }

        printf("%-7s%-11s\n", "[NEW]", cmd->name);
    }

    return rc;
}


static int compare_command_names(const void *a, const void *b)
{
    const command_t *ca = *(const command_t * const *)a;
    const command_t *cb = *(const command_t * const *)b;

    return strcmp(ca->name, cb->name);
}

static void usage(void)
{
    const command_t *cmd;
    const command_t *sorted[sizeof(commands) / sizeof(commands[0]) - 1];
    size_t count = 0;
    size_t i;

    printf(
        "\nnshbox %s - tiny Linux toolbox\n\n",
        NSHBOX_VERSION
    );

    printf("Usage:\n");
    printf("  nshbox <command> [arguments]\n\n");

    printf("Commands:\n");

    /* Printed alphabetically for easy scanning - commands[] itself stays
     * grouped by theme in source order (checksums together, DNS commands
     * together, base64/jwt/json together, ...), which is more readable
     * when working on the code; only the display order differs here.
     * "install" is excluded from this list and shown in its own "Setup:"
     * section below instead, since it changes the filesystem rather than
     * reading/reporting anything, unlike every other command here. */
    for (cmd = commands; cmd->name; cmd++) {
        if (strcmp(cmd->name, "install") == 0)
            continue;
        sorted[count++] = cmd;
    }

    qsort(sorted, count, sizeof(sorted[0]), compare_command_names);

    for (i = 0; i < count; i++) {
        printf(
            "  %-13s %s\n",
            sorted[i]->name,
            sorted[i]->help
        );
    }

    printf("\nSetup:\n");

    for (cmd = commands; cmd->name; cmd++) {
        if (strcmp(cmd->name, "install") != 0)
            continue;

        printf(
            "  %-13s %s\n",
            cmd->name,
            cmd->help
        );
    }

    printf("\n");
}


/* ------------------------------------------------------------------ */
/* dispatch                                                           */
/* ------------------------------------------------------------------ */

/* "--JSON"/"--Json" is an opt-in pretty-printed variant of whichever
 * --json a command already supports (ps/du/find/dig/nslookup/uptime/
 * sysinfo/netstat/stat/the checksum commands) -
 * reusing json_pretty_print() rather than teaching each of those
 * commands its own separate pretty-printing path. Rewrites the matched
 * argv entry to "--json" in place, so the target command's own,
 * unchanged, already-tested arg parser sees exactly the flag it already
 * understands, then captures everything that command writes to stdout
 * via open_memstream() (glibc's/POSIX's stdout is a real, reassignable
 * FILE* global, not just an opaque macro - this is standard, portable
 * behavior on this project's actual target platforms, not a hack
 * specific to one libc) instead of letting it reach the terminal
 * directly, and re-emits the captured output pretty-printed once the
 * command has finished. A command that does not understand --json at
 * all just gets its own normal "unrecognized option" from --json.
 *
 * One accepted tradeoff: this rewrite happens before the target
 * command ever sees its own argv, so a literal "--JSON"/"--Json" meant as
 * a genuine argument to some other command (e.g. a grep pattern) would
 * be misread as this flag instead - accepted because both spellings are
 * unusual enough in practice, and opt-in, to not be worth a per-command
 * allowlist here - see nshbox/README.md. */
static int dispatch_command(const command_t *cmd, int argc, char **argv)
{
    int i;
    int pretty = 0;
    FILE *captured;
    char *buf = NULL;
    size_t buf_len = 0;
    FILE *real_stdout;
    int rc;

    for (i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--JSON") || !strcmp(argv[i], "--Json")) {
            argv[i] = (char *)"--json";
            pretty = 1;
        }
    }

    if (!pretty)
        return cmd->func(argc, argv);

    captured = open_memstream(&buf, &buf_len);
    if (!captured) {
        perror("open_memstream");
        return 1;
    }

    fflush(stdout);
    real_stdout = stdout;
    stdout = captured;

    rc = cmd->func(argc, argv);

    fflush(stdout);
    stdout = real_stdout;
    fclose(captured);

    if (buf_len > 0) {
        FILE *in = fmemopen(buf, buf_len, "r");

        if (!in) {
            perror("fmemopen");
            rc = rc ? rc : 1;
        } else {
            int pretty_rc = json_pretty_print(in, stdout);

            fclose(in);
            if (rc == 0)
                rc = pretty_rc;
        }
    }

    free(buf);
    return rc;
}


/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

int main(int argc, char **argv)
{
    const command_t *cmd;
    const char *name;

    name = program_name(argv[0]);

    /*
     * Normal:
     *
     *   nshbox netstat -l
     *
     * BusyBox-style symlink:
     *
     *   netstat -> nshbox
     *   netstat -l
     */

    if (strcmp(name, "nshbox") == 0) {

        if (argc < 2) {
            usage();
            return 0;
        }

        if (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0) {
            printf("nshbox %s\n", NSHBOX_VERSION);
            return 0;
        }

        name = argv[1];

        argc--;
        argv++;
    }

    for (cmd = commands; cmd->name; cmd++) {
        if (strcmp(name, cmd->name) == 0)
            return dispatch_command(cmd, argc, argv);
    }

    fprintf(
        stderr,
        "nshbox: unknown command '%s'\n\n",
        name
    );

    usage();

    return 1;
}
