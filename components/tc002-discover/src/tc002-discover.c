/*
 * tc002-discover.c
 *
 * Discover Ulanzi TC002 devices.
 *
 * TC002 broadcasts approximately once per second:
 *
 *     UDP -> 255.255.255.255:55555
 *
 * Example payload:
 *
 *     Ulanzi TC002 a95f:ccc4b277a95f:B0D26I008U3670767:true
 *
 * Features:
 *
 *   - Passive UDP discovery
 *   - Multiple-device discovery with --all
 *   - Selection by serial, MAC or device name
 *   - Persistent cache of previously discovered devices
 *   - Fast cached-IP availability check using TCP/5555
 *   - Reverse DNS lookup (PTR / in-addr.arpa)
 *   - Forward validation of PTR result:
 *
 *         IP -> PTR -> hostname -> A -> original IP
 *
 *   - INI output
 *   - JSON output
 *   - Absolute discovery timeout
 *
 * Default cache:
 *
 *     $HOME/.tc002-discover.cache
 *
 * Fallback if HOME is unavailable:
 *
 *     /tmp/tc002-discover.cache
 *
 * Exit codes:
 *
 *     0   Device found
 *     1   No matching TC002 found
 *     2   Command-line error
 *     3   Reserved for cache/configuration errors
 *     4   Network/socket error
 */

#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define DISCOVERY_PORT       55555
#define ADB_PORT             5555

#define DEFAULT_TIMEOUT      3
#define CONNECT_TIMEOUT_MS   400

#define PREFIX               "Ulanzi TC002 "
#define BUFFER_SIZE          512

#define MAX_DEVICES          32

#define NAME_SIZE            128
#define HOSTNAME_SIZE        256
#define SERIAL_SIZE          128
#define MAC_SIZE             18
#define CACHE_FILE_SIZE      512

#define CACHE_FILENAME       ".tc002-discover.cache"
#define FALLBACK_CACHE_FILE  "/tmp/tc002-discover.cache"

typedef struct
{
    char szName[NAME_SIZE];
    char szIP[INET_ADDRSTRLEN];
    char szHostname[HOSTNAME_SIZE];
    char szMAC[MAC_SIZE];
    char szSerial[SERIAL_SIZE];

    int state;
    int state_known;
    int reachable;
    int discovered;
    int from_cache;
} TC002_DEVICE;

typedef struct
{
    int json;
    int all;
    int timeout;
    int refresh;
    int no_cache;

    const char *pszSerial;
    const char *pszMAC;
    const char *pszName;
    const char *pszCacheFile;

    char szCacheFile[CACHE_FILE_SIZE];
} TC002_OPTIONS;


/* ---------------------------------------------------------------------- */
/* Utility                                                                */
/* ---------------------------------------------------------------------- */

static void usage(const char *pszProgram)
{
    fprintf(stderr,
        "Usage: %s [options]\n"
        "\n"
        "Options:\n"
        "  --json                 JSON output\n"
        "  --all                  Report all discovered devices\n"
        "  --timeout SECONDS      Discovery timeout (default: %d)\n"
        "  --serial SERIAL        Select device by serial number\n"
        "  --mac MAC              Select device by MAC address\n"
        "  --name NAME            Select device by TC002 name\n"
        "  --refresh              Ignore cached reachability and use UDP\n"
        "  --no-cache             Do not read or write cache\n"
        "  --cache FILE           Use alternate cache file\n"
        "  -h, --help             Show this help\n",
        pszProgram, DEFAULT_TIMEOUT);
}

static int parse_positive_int(const char *pszValue, int *pValue)
{
    char *pszEnd = NULL;
    long value = 0;

    errno = 0;
    value = strtol(pszValue, &pszEnd, 10);

    if (errno != 0 || *pszValue == '\0' || *pszEnd != '\0' || value <= 0 || value > 86400)
    {
        return -1;
    }

    *pValue = (int)value;
    return 0;
}

static long long monotonic_ms(void)
{
    struct timespec Time = {0};

    if (clock_gettime(CLOCK_MONOTONIC, &Time) != 0)
    {
        return -1;
    }

    return (long long)Time.tv_sec * 1000LL + (long long)Time.tv_nsec / 1000000LL;
}

static void copy_string(char *pszDestination, size_t destination_size, const char *pszSource)
{
    if (destination_size == 0)
    {
        return;
    }

    if (pszSource == NULL)
    {
        pszSource = "";
    }

    snprintf(pszDestination, destination_size, "%s", pszSource);
}

static void trim_newline(char *pszString)
{
    size_t length = strlen(pszString);

    while (length > 0 && (pszString[length - 1] == '\n' || pszString[length - 1] == '\r'))
    {
        pszString[--length] = '\0';
    }
}

static void format_mac(const char *pszSource, char *pszDestination, size_t destination_size)
{
    char szCompact[13] = {0};
    size_t i = 0;
    size_t count = 0;

    for (i = 0; pszSource[i] != '\0' && count < 12; ++i)
    {
        if (pszSource[i] == ':' || pszSource[i] == '-')
        {
            continue;
        }

        szCompact[count++] = pszSource[i];
    }

    szCompact[count] = '\0';

    if (count == 12 && destination_size >= MAC_SIZE)
    {
        snprintf(pszDestination, destination_size, "%.2s:%.2s:%.2s:%.2s:%.2s:%.2s",
            szCompact, szCompact + 2, szCompact + 4, szCompact + 6, szCompact + 8, szCompact + 10);
    }
    else
    {
        copy_string(pszDestination, destination_size, pszSource);
    }
}


/* ---------------------------------------------------------------------- */
/* JSON                                                                   */
/* ---------------------------------------------------------------------- */

static void print_json_string(const char *pszString)
{
    const unsigned char *pszPos = (const unsigned char *)pszString;

    putchar('"');

    while (*pszPos)
    {
        switch (*pszPos)
        {
            case '"':
                fputs("\\\"", stdout);
                break;

            case '\\':
                fputs("\\\\", stdout);
                break;

            case '\b':
                fputs("\\b", stdout);
                break;

            case '\f':
                fputs("\\f", stdout);
                break;

            case '\n':
                fputs("\\n", stdout);
                break;

            case '\r':
                fputs("\\r", stdout);
                break;

            case '\t':
                fputs("\\t", stdout);
                break;

            default:
                if (*pszPos < 0x20)
                {
                    printf("\\u%04x", *pszPos);
                }
                else
                {
                    putchar(*pszPos);
                }
                break;
        }

        ++pszPos;
    }

    putchar('"');
}

static void print_json_device(const TC002_DEVICE *pDevice)
{
    fputs("{\"name\":", stdout);
    print_json_string(pDevice->szName);

    fputs(",\"ip\":", stdout);
    print_json_string(pDevice->szIP);

    fputs(",\"hostname\":", stdout);
    print_json_string(pDevice->szHostname);

    fputs(",\"mac\":", stdout);
    print_json_string(pDevice->szMAC);

    fputs(",\"serial\":", stdout);
    print_json_string(pDevice->szSerial);

    fputs(",\"state\":", stdout);

    if (!pDevice->state_known)
    {
        fputs("null", stdout);
    }
    else
    {
        fputs(pDevice->state ? "true" : "false", stdout);
    }

    fputs(",\"reachable\":", stdout);
    fputs(pDevice->reachable ? "true" : "false", stdout);

    fputs(",\"discovered\":", stdout);
    fputs(pDevice->discovered ? "true" : "false", stdout);

    putchar('}');
}


/* ---------------------------------------------------------------------- */
/* INI                                                                    */
/* ---------------------------------------------------------------------- */

static void print_ini_device(const TC002_DEVICE *pDevice, int index, int multiple)
{
    if (multiple)
    {
        printf("[device.%d]\n", index + 1);
    }
    else
    {
        printf("[device]\n");
    }

    printf("name=%s\n", pDevice->szName);
    printf("ip=%s\n", pDevice->szIP);
    printf("hostname=%s\n", pDevice->szHostname);
    printf("mac=%s\n", pDevice->szMAC);
    printf("serial=%s\n", pDevice->szSerial);

    if (pDevice->state_known)
    {
        printf("state=%s\n", pDevice->state ? "true" : "false");
    }
    else
    {
        printf("state=\n");
    }

    printf("reachable=%s\n", pDevice->reachable ? "true" : "false");
    printf("discovered=%s\n", pDevice->discovered ? "true" : "false");
}


/* ---------------------------------------------------------------------- */
/* Selection                                                              */
/* ---------------------------------------------------------------------- */

static int device_matches(const TC002_DEVICE *pDevice, const TC002_OPTIONS *pOptions)
{
    char szFormattedMAC[MAC_SIZE] = {0};

    if (pOptions->pszSerial != NULL && strcmp(pDevice->szSerial, pOptions->pszSerial) != 0)
    {
        return 0;
    }

    if (pOptions->pszName != NULL && strcmp(pDevice->szName, pOptions->pszName) != 0)
    {
        return 0;
    }

    if (pOptions->pszMAC != NULL)
    {
        format_mac(pOptions->pszMAC, szFormattedMAC, sizeof(szFormattedMAC));

        if (strcasecmp(pDevice->szMAC, szFormattedMAC) != 0)
        {
            return 0;
        }
    }

    return 1;
}


/* ---------------------------------------------------------------------- */
/* DNS                                                                    */
/* ---------------------------------------------------------------------- */

static int hostname_resolves_to_ip(const char *pszHostname, const char *pszIP)
{
    struct addrinfo Hints = {0};
    struct addrinfo *pResult = NULL;
    struct addrinfo *pAddress = NULL;
    struct in_addr ExpectedAddress = {0};

    int rc = 0;
    int found = 0;

    if (inet_pton(AF_INET, pszIP, &ExpectedAddress) != 1)
    {
        return 0;
    }

    Hints.ai_family = AF_INET;
    Hints.ai_socktype = SOCK_STREAM;

    rc = getaddrinfo(pszHostname, NULL, &Hints, &pResult);

    if (rc != 0)
    {
        return 0;
    }

    for (pAddress = pResult; pAddress != NULL; pAddress = pAddress->ai_next)
    {
        struct sockaddr_in *pSocketAddress = NULL;

        if (pAddress->ai_family != AF_INET)
        {
            continue;
        }

        pSocketAddress = (struct sockaddr_in *)pAddress->ai_addr;

        if (memcmp(&pSocketAddress->sin_addr, &ExpectedAddress, sizeof(ExpectedAddress)) == 0)
        {
            found = 1;
            break;
        }
    }

    freeaddrinfo(pResult);
    return found;
}

static int validated_reverse_dns(const char *pszIP, char *pszHostname, size_t hostname_size)
{
    struct sockaddr_in Address = {0};
    char szPTRName[HOSTNAME_SIZE] = {0};
    int rc = 0;

    pszHostname[0] = '\0';

    Address.sin_family = AF_INET;

    if (inet_pton(AF_INET, pszIP, &Address.sin_addr) != 1)
    {
        return 0;
    }

    rc = getnameinfo((struct sockaddr *)&Address, sizeof(Address), szPTRName, sizeof(szPTRName),
        NULL, 0, NI_NAMEREQD);

    if (rc != 0)
    {
        return 0;
    }

    if (!hostname_resolves_to_ip(szPTRName, pszIP))
    {
        return 0;
    }

    copy_string(pszHostname, hostname_size, szPTRName);
    return 1;
}


/* ---------------------------------------------------------------------- */
/* TCP availability                                                       */
/* ---------------------------------------------------------------------- */

static int tcp_connect_test(const char *pszIP, unsigned short port, int timeout_ms)
{
    int fd = -1;
    int flags = 0;
    int rc = 0;
    int error = 0;

    socklen_t error_length = sizeof(error);
    struct sockaddr_in Address = {0};
    struct pollfd PollFD = {0};

    fd = socket(AF_INET, SOCK_STREAM, 0);

    if (fd < 0)
    {
        return 0;
    }

    flags = fcntl(fd, F_GETFL, 0);

    if (flags < 0)
    {
        close(fd);
        return 0;
    }

    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0)
    {
        close(fd);
        return 0;
    }

    Address.sin_family = AF_INET;
    Address.sin_port = htons(port);

    if (inet_pton(AF_INET, pszIP, &Address.sin_addr) != 1)
    {
        close(fd);
        return 0;
    }

    rc = connect(fd, (struct sockaddr *)&Address, sizeof(Address));

    if (rc == 0)
    {
        close(fd);
        return 1;
    }

    if (errno != EINPROGRESS)
    {
        close(fd);
        return 0;
    }

    PollFD.fd = fd;
    PollFD.events = POLLOUT;

    rc = poll(&PollFD, 1, timeout_ms);

    if (rc <= 0)
    {
        close(fd);
        return 0;
    }

    error = 0;
    error_length = sizeof(error);

    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_length) < 0)
    {
        close(fd);
        return 0;
    }

    close(fd);
    return error == 0;
}


/* ---------------------------------------------------------------------- */
/* Device collection                                                      */
/* ---------------------------------------------------------------------- */

static int find_device(TC002_DEVICE *pDevices, int count, const char *pszSerial, const char *pszMAC)
{
    int i = 0;

    if (pszSerial != NULL && pszSerial[0] != '\0')
    {
        for (i = 0; i < count; ++i)
        {
            if (strcmp(pDevices[i].szSerial, pszSerial) == 0)
            {
                return i;
            }
        }
    }

    if (pszMAC != NULL && pszMAC[0] != '\0')
    {
        for (i = 0; i < count; ++i)
        {
            if (strcasecmp(pDevices[i].szMAC, pszMAC) == 0)
            {
                return i;
            }
        }
    }

    return -1;
}

static int add_or_update_device(TC002_DEVICE *pDevices, int *pCount,
    const TC002_DEVICE *pIncomingDevice)
{
    int index = find_device(pDevices, *pCount, pIncomingDevice->szSerial, pIncomingDevice->szMAC);

    if (index < 0)
    {
        if (*pCount >= MAX_DEVICES)
        {
            return -1;
        }

        pDevices[*pCount] = *pIncomingDevice;
        index = *pCount;
        ++(*pCount);

        return index;
    }

    if (pIncomingDevice->discovered)
    {
        copy_string(pDevices[index].szName, sizeof(pDevices[index].szName), pIncomingDevice->szName);
        copy_string(pDevices[index].szIP, sizeof(pDevices[index].szIP), pIncomingDevice->szIP);
        copy_string(pDevices[index].szHostname, sizeof(pDevices[index].szHostname),
            pIncomingDevice->szHostname);
        copy_string(pDevices[index].szMAC, sizeof(pDevices[index].szMAC), pIncomingDevice->szMAC);
        copy_string(pDevices[index].szSerial, sizeof(pDevices[index].szSerial), pIncomingDevice->szSerial);

        pDevices[index].state = pIncomingDevice->state;
        pDevices[index].state_known = pIncomingDevice->state_known;
        pDevices[index].reachable = pIncomingDevice->reachable;
        pDevices[index].discovered = 1;
        pDevices[index].from_cache = 0;
    }

    return index;
}


/* ---------------------------------------------------------------------- */
/* UDP packet parsing                                                     */
/* ---------------------------------------------------------------------- */

static int parse_tc002_packet(char *pszBuffer, const char *pszIP, TC002_DEVICE *pDevice)
{
    char *pszName = NULL;
    char *pszMAC = NULL;
    char *pszSerial = NULL;
    char *pszState = NULL;
    char *pszPos = NULL;

    char szFormattedMAC[MAC_SIZE] = {0};

    if (strncmp(pszBuffer, PREFIX, strlen(PREFIX)) != 0)
    {
        return 0;
    }

    pszName = pszBuffer;

    pszPos = strchr(pszName, ':');

    if (pszPos == NULL)
    {
        return 0;
    }

    *pszPos++ = '\0';
    pszMAC = pszPos;

    pszPos = strchr(pszMAC, ':');

    if (pszPos == NULL)
    {
        return 0;
    }

    *pszPos++ = '\0';
    pszSerial = pszPos;

    pszPos = strchr(pszSerial, ':');

    if (pszPos == NULL)
    {
        return 0;
    }

    *pszPos++ = '\0';
    pszState = pszPos;

    if (strchr(pszState, ':') != NULL)
    {
        return 0;
    }

    if (pszName[0] == '\0' || pszMAC[0] == '\0' ||
        pszSerial[0] == '\0' || pszState[0] == '\0')
    {
        return 0;
    }

    format_mac(pszMAC, szFormattedMAC, sizeof(szFormattedMAC));

    *pDevice = (TC002_DEVICE){0};

    copy_string(pDevice->szName, sizeof(pDevice->szName), pszName);
    copy_string(pDevice->szIP, sizeof(pDevice->szIP), pszIP);
    copy_string(pDevice->szMAC, sizeof(pDevice->szMAC), szFormattedMAC);
    copy_string(pDevice->szSerial, sizeof(pDevice->szSerial), pszSerial);

    if (strcmp(pszState, "true") == 0)
    {
        pDevice->state = 1;
        pDevice->state_known = 1;
    }
    else if (strcmp(pszState, "false") == 0)
    {
        pDevice->state = 0;
        pDevice->state_known = 1;
    }
    else
    {
        return 0;
    }

    pDevice->discovered = 1;
    return 1;
}


/* ---------------------------------------------------------------------- */
/* Cache                                                                  */
/* ---------------------------------------------------------------------- */

static int load_cache(const char *pszFilename, TC002_DEVICE *pDevices, int *pCount)
{
    FILE *pFile = NULL;
    char szLine[BUFFER_SIZE] = {0};
    TC002_DEVICE CurrentDevice = {0};
    int have_device = 0;

    pFile = fopen(pszFilename, "r");

    if (pFile == NULL)
    {
        if (errno == ENOENT)
        {
            return 0;
        }

        return -1;
    }

    while (fgets(szLine, sizeof(szLine), pFile) != NULL)
    {
        char *pszEquals = NULL;
        char *pszKey = NULL;
        char *pszValue = NULL;

        trim_newline(szLine);

        if (szLine[0] == '\0')
        {
            continue;
        }

        if (szLine[0] == '#' || szLine[0] == ';')
        {
            continue;
        }

        if (szLine[0] == '[')
        {
            if (have_device && CurrentDevice.szSerial[0] != '\0')
            {
                CurrentDevice.from_cache = 1;
                add_or_update_device(pDevices, pCount, &CurrentDevice);
            }

            CurrentDevice = (TC002_DEVICE){0};
            have_device = 1;
            continue;
        }

        if (!have_device)
        {
            continue;
        }

        pszEquals = strchr(szLine, '=');

        if (pszEquals == NULL)
        {
            continue;
        }

        *pszEquals++ = '\0';

        pszKey = szLine;
        pszValue = pszEquals;

        if (strcmp(pszKey, "name") == 0)
        {
            copy_string(CurrentDevice.szName, sizeof(CurrentDevice.szName), pszValue);
        }
        else if (strcmp(pszKey, "ip") == 0)
        {
            copy_string(CurrentDevice.szIP, sizeof(CurrentDevice.szIP), pszValue);
        }
        else if (strcmp(pszKey, "hostname") == 0)
        {
            copy_string(CurrentDevice.szHostname, sizeof(CurrentDevice.szHostname), pszValue);
        }
        else if (strcmp(pszKey, "mac") == 0)
        {
            format_mac(pszValue, CurrentDevice.szMAC, sizeof(CurrentDevice.szMAC));
        }
        else if (strcmp(pszKey, "serial") == 0)
        {
            copy_string(CurrentDevice.szSerial, sizeof(CurrentDevice.szSerial), pszValue);
        }
        else if (strcmp(pszKey, "state") == 0)
        {
            if (strcmp(pszValue, "true") == 0)
            {
                CurrentDevice.state = 1;
                CurrentDevice.state_known = 1;
            }
            else if (strcmp(pszValue, "false") == 0)
            {
                CurrentDevice.state = 0;
                CurrentDevice.state_known = 1;
            }
        }
    }

    if (have_device && CurrentDevice.szSerial[0] != '\0')
    {
        CurrentDevice.from_cache = 1;
        add_or_update_device(pDevices, pCount, &CurrentDevice);
    }

    fclose(pFile);
    return 0;
}

static int save_cache(const char *pszFilename, const TC002_DEVICE *pDevices, int count)
{
    char szTemporaryFilename[CACHE_FILE_SIZE + 16] = {0};
    FILE *pFile = NULL;
    int i = 0;

    if (snprintf(szTemporaryFilename, sizeof(szTemporaryFilename), "%s.tmp", pszFilename) >=
        (int)sizeof(szTemporaryFilename))
    {
        return -1;
    }

    pFile = fopen(szTemporaryFilename, "w");

    if (pFile == NULL)
    {
        return -1;
    }

    for (i = 0; i < count; ++i)
    {
        const TC002_DEVICE *pDevice = &pDevices[i];

        if (pDevice->szSerial[0] == '\0')
        {
            continue;
        }

        fprintf(pFile, "[device.%d]\n", i + 1);
        fprintf(pFile, "name=%s\n", pDevice->szName);
        fprintf(pFile, "ip=%s\n", pDevice->szIP);
        fprintf(pFile, "hostname=%s\n", pDevice->szHostname);
        fprintf(pFile, "mac=%s\n", pDevice->szMAC);
        fprintf(pFile, "serial=%s\n", pDevice->szSerial);

        if (pDevice->state_known)
        {
            fprintf(pFile, "state=%s\n", pDevice->state ? "true" : "false");
        }
        else
        {
            fprintf(pFile, "state=\n");
        }

        fprintf(pFile, "\n");
    }

    if (fclose(pFile) != 0)
    {
        unlink(szTemporaryFilename);
        return -1;
    }

    if (rename(szTemporaryFilename, pszFilename) != 0)
    {
        unlink(szTemporaryFilename);
        return -1;
    }

    return 0;
}


/* ---------------------------------------------------------------------- */
/* Cached device validation                                               */
/* ---------------------------------------------------------------------- */

static void validate_cached_devices(TC002_DEVICE *pDevices, int count)
{
    int i = 0;

    for (i = 0; i < count; ++i)
    {
        TC002_DEVICE *pDevice = &pDevices[i];

        pDevice->reachable = 0;
        pDevice->discovered = 0;

        if (pDevice->szIP[0] == '\0')
        {
            continue;
        }

        if (!tcp_connect_test(pDevice->szIP, ADB_PORT, CONNECT_TIMEOUT_MS))
        {
            continue;
        }

        pDevice->reachable = 1;
        pDevice->szHostname[0] = '\0';

        validated_reverse_dns(pDevice->szIP, pDevice->szHostname, sizeof(pDevice->szHostname));
    }
}


/* ---------------------------------------------------------------------- */
/* UDP discovery                                                          */
/* ---------------------------------------------------------------------- */

static int discover_udp(TC002_DEVICE *pDevices, int *pCount, const TC002_OPTIONS *pOptions)
{
    int fd = -1;
    int one = 1;

    struct sockaddr_in Address = {0};

    long long start = 0;
    long long deadline = 0;

    fd = socket(AF_INET, SOCK_DGRAM, 0);

    if (fd < 0)
    {
        perror("socket");
        return -1;
    }

    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0)
    {
        perror("setsockopt SO_REUSEADDR");
        close(fd);
        return -1;
    }

    Address.sin_family = AF_INET;
    Address.sin_addr.s_addr = htonl(INADDR_ANY);
    Address.sin_port = htons(DISCOVERY_PORT);

    if (bind(fd, (struct sockaddr *)&Address, sizeof(Address)) < 0)
    {
        perror("bind");
        close(fd);
        return -1;
    }

    start = monotonic_ms();

    if (start < 0)
    {
        perror("clock_gettime");
        close(fd);
        return -1;
    }

    deadline = start + (long long)pOptions->timeout * 1000LL;

    for (;;)
    {
        struct pollfd PollFD = {0};
        long long now = 0;
        long long remaining = 0;
        int rc = 0;

        now = monotonic_ms();

        if (now < 0)
        {
            perror("clock_gettime");
            close(fd);
            return -1;
        }

        remaining = deadline - now;

        if (remaining <= 0)
        {
            break;
        }

        PollFD.fd = fd;
        PollFD.events = POLLIN;

        rc = poll(&PollFD, 1, remaining > 2147483647LL ? 2147483647 : (int)remaining);

        if (rc < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }

            perror("poll");
            close(fd);
            return -1;
        }

        if (rc == 0)
        {
            break;
        }

        if (PollFD.revents & POLLIN)
        {
            struct sockaddr_in PeerAddress = {0};
            socklen_t peer_length = sizeof(PeerAddress);

            char szBuffer[BUFFER_SIZE] = {0};
            char szIP[INET_ADDRSTRLEN] = {0};

            ssize_t length = 0;
            TC002_DEVICE IncomingDevice = {0};
            int index = -1;

            length = recvfrom(fd, szBuffer, sizeof(szBuffer) - 1, 0,
                (struct sockaddr *)&PeerAddress, &peer_length);

            if (length < 0)
            {
                if (errno == EINTR)
                {
                    continue;
                }

                perror("recvfrom");
                close(fd);
                return -1;
            }

            szBuffer[length] = '\0';

            if (inet_ntop(AF_INET, &PeerAddress.sin_addr, szIP, sizeof(szIP)) == NULL)
            {
                continue;
            }

            if (!parse_tc002_packet(szBuffer, szIP, &IncomingDevice))
            {
                continue;
            }

            if (!device_matches(&IncomingDevice, pOptions))
            {
                continue;
            }

            IncomingDevice.reachable = 1;

            validated_reverse_dns(IncomingDevice.szIP, IncomingDevice.szHostname,
                sizeof(IncomingDevice.szHostname));

            index = add_or_update_device(pDevices, pCount, &IncomingDevice);

            if (index < 0)
            {
                fprintf(stderr, "Too many TC002 devices\n");
                close(fd);
                return -1;
            }

            if (!pOptions->all)
            {
                close(fd);
                return 1;
            }
        }
    }

    close(fd);
    return 0;
}


/* ---------------------------------------------------------------------- */
/* Result collection                                                      */
/* ---------------------------------------------------------------------- */

static int collect_matching_devices(const TC002_DEVICE *pDevices, int count,
    const TC002_OPTIONS *pOptions, int *pIndexes, int max_indexes)
{
    int i = 0;
    int result_count = 0;

    for (i = 0; i < count && result_count < max_indexes; ++i)
    {
        if (!device_matches(&pDevices[i], pOptions))
        {
            continue;
        }

        if (!pDevices[i].reachable && !pDevices[i].discovered)
        {
            continue;
        }

        pIndexes[result_count++] = i;

        if (!pOptions->all)
        {
            break;
        }
    }

    return result_count;
}


/* ---------------------------------------------------------------------- */
/* Result output                                                          */
/* ---------------------------------------------------------------------- */

static void print_results(const TC002_DEVICE *pDevices, const int *pIndexes,
    int result_count, const TC002_OPTIONS *pOptions)
{
    int i = 0;

    if (pOptions->json)
    {
        if (!pOptions->all)
        {
            print_json_device(&pDevices[pIndexes[0]]);
            putchar('\n');
            return;
        }

        putchar('[');

        for (i = 0; i < result_count; ++i)
        {
            if (i != 0)
            {
                putchar(',');
            }

            print_json_device(&pDevices[pIndexes[i]]);
        }

        fputs("]\n", stdout);
        return;
    }

    for (i = 0; i < result_count; ++i)
    {
        if (i != 0)
        {
            putchar('\n');
        }

        print_ini_device(&pDevices[pIndexes[i]], i, pOptions->all);
    }
}


/* ---------------------------------------------------------------------- */
/* Command line                                                           */
/* ---------------------------------------------------------------------- */

static void set_default_cache_file(TC002_OPTIONS *pOptions)
{
    const char *pszHome = getenv("HOME");

    if (pszHome != NULL && pszHome[0] != '\0')
    {
        int length = snprintf(pOptions->szCacheFile, sizeof(pOptions->szCacheFile),
            "%s/%s", pszHome, CACHE_FILENAME);

        if (length > 0 && length < (int)sizeof(pOptions->szCacheFile))
        {
            pOptions->pszCacheFile = pOptions->szCacheFile;
            return;
        }
    }

    copy_string(pOptions->szCacheFile, sizeof(pOptions->szCacheFile), FALLBACK_CACHE_FILE);
    pOptions->pszCacheFile = pOptions->szCacheFile;
}

static int parse_arguments(int argc, char **argv, TC002_OPTIONS *pOptions)
{
    int i = 0;

    *pOptions = (TC002_OPTIONS){0};

    pOptions->timeout = DEFAULT_TIMEOUT;
    set_default_cache_file(pOptions);

    for (i = 1; i < argc; ++i)
    {
        if (strcmp(argv[i], "--json") == 0)
        {
            pOptions->json = 1;
            continue;
        }

        if (strcmp(argv[i], "--all") == 0)
        {
            pOptions->all = 1;
            continue;
        }

        if (strcmp(argv[i], "--refresh") == 0)
        {
            pOptions->refresh = 1;
            continue;
        }

        if (strcmp(argv[i], "--no-cache") == 0)
        {
            pOptions->no_cache = 1;
            continue;
        }

        if (strcmp(argv[i], "--timeout") == 0)
        {
            ++i;

            if (i >= argc)
            {
                fprintf(stderr, "Missing value for --timeout\n");
                return -1;
            }

            if (parse_positive_int(argv[i], &pOptions->timeout) != 0)
            {
                fprintf(stderr, "Invalid timeout: %s\n", argv[i]);
                return -1;
            }

            continue;
        }

        if (strcmp(argv[i], "--serial") == 0)
        {
            ++i;

            if (i >= argc)
            {
                fprintf(stderr, "Missing value for --serial\n");
                return -1;
            }

            pOptions->pszSerial = argv[i];
            continue;
        }

        if (strcmp(argv[i], "--mac") == 0)
        {
            ++i;

            if (i >= argc)
            {
                fprintf(stderr, "Missing value for --mac\n");
                return -1;
            }

            pOptions->pszMAC = argv[i];
            continue;
        }

        if (strcmp(argv[i], "--name") == 0)
        {
            ++i;

            if (i >= argc)
            {
                fprintf(stderr, "Missing value for --name\n");
                return -1;
            }

            pOptions->pszName = argv[i];
            continue;
        }

        if (strcmp(argv[i], "--cache") == 0)
        {
            ++i;

            if (i >= argc)
            {
                fprintf(stderr, "Missing value for --cache\n");
                return -1;
            }

            pOptions->pszCacheFile = argv[i];
            continue;
        }

        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0)
        {
            usage(argv[0]);
            exit(0);
        }

        fprintf(stderr, "Unknown option: %s\n", argv[i]);
        return -1;
    }

    return 0;
}


/* ---------------------------------------------------------------------- */
/* Main                                                                   */
/* ---------------------------------------------------------------------- */

int main(int argc, char **argv)
{
    TC002_OPTIONS Options = {0};
    TC002_DEVICE Devices[MAX_DEVICES] = {0};

    int Indexes[MAX_DEVICES] = {0};

    int count = 0;
    int result_count = 0;
    int rc = 0;

    if (parse_arguments(argc, argv, &Options) != 0)
    {
        usage(argv[0]);
        return 2;
    }

    if (!Options.no_cache)
    {
        rc = load_cache(Options.pszCacheFile, Devices, &count);

        if (rc < 0)
        {
            fprintf(stderr, "Warning: cannot read cache: %s: %s\n",
                Options.pszCacheFile, strerror(errno));
        }
    }

    /*
     * Fast path: try previously known IP addresses before waiting
     * for another TC002 UDP announcement.
     */

    if (!Options.refresh && !Options.no_cache && count > 0)
    {
        validate_cached_devices(Devices, count);

        result_count = collect_matching_devices(Devices, count, &Options, Indexes, MAX_DEVICES);

        if (!Options.all && result_count > 0)
        {
            print_results(Devices, Indexes, result_count, &Options);
            return 0;
        }
    }

    rc = discover_udp(Devices, &count, &Options);

    if (rc < 0)
    {
        return 4;
    }

    if (!Options.no_cache)
    {
        if (save_cache(Options.pszCacheFile, Devices, count) != 0)
        {
            fprintf(stderr, "Warning: cannot write cache: %s: %s\n",
                Options.pszCacheFile, strerror(errno));
        }
    }

    result_count = collect_matching_devices(Devices, count, &Options, Indexes, MAX_DEVICES);

    if (result_count == 0)
    {
        if (Options.json && Options.all)
        {
            fputs("[]\n", stdout);
        }

        fprintf(stderr, "No TC002 found\n");
        return 1;
    }

    print_results(Devices, Indexes, result_count, &Options);
    return 0;
}
