/*
 * BEGIN FlyThings passwd fallback
 *
 * The device has no usable passwd database. Try the system lookup first
 * and synthesize a root entry only when that lookup fails.
 *
 * Required linker options:
 *
 *   -Wl,--wrap=getpwnam
 *   -Wl,--wrap=getpwuid
 */

#include <sys/types.h>
#include <pwd.h>
#include <stdio.h>
#include <string.h>

struct passwd *__real_getpwnam(const char *name);
struct passwd *__real_getpwuid(uid_t uid);

static struct passwd *embedded_root_passwd(void)
{
    static struct passwd fakepw;
    static int initialized = 0;

    if (!initialized) {
        memset(&fakepw, 0, sizeof(fakepw));

        fakepw.pw_name   = (char *)"root";
        fakepw.pw_passwd = (char *)"x";
        fakepw.pw_uid    = (uid_t)0;
        fakepw.pw_gid    = (gid_t)0;
        fakepw.pw_gecos  = (char *)"root";
        fakepw.pw_dir    = (char *)"/data/home";
        fakepw.pw_shell  = (char *)"/bin/sh";

        initialized = 1;
    }

    return &fakepw;
}

struct passwd *__wrap_getpwnam(const char *name)
{
    struct passwd *pw;

    if (name == NULL)
        return NULL;

    pw = __real_getpwnam(name);

    if (pw != NULL)
        return pw;

    if (strcmp(name, "root") == 0) {
        pw = embedded_root_passwd();

        dropbear_log(LOG_INFO,
                "Using synthetic passwd entry: "
                "name=%s uid=%lu gid=%lu home=%s shell=%s",
                pw->pw_name,
                (unsigned long)pw->pw_uid,
                (unsigned long)pw->pw_gid,
                pw->pw_dir,
                pw->pw_shell);

        return pw;
    }

    dropbear_log(LOG_WARNING,
            "No system or synthetic passwd entry for user \"%s\"",
            name);

    return NULL;
}

struct passwd *__wrap_getpwuid(uid_t uid)
{
    struct passwd *pw = __real_getpwuid(uid);

    if (pw != NULL)
        return pw;

    if (uid == (uid_t)0) {
        pw = embedded_root_passwd();

        dropbear_log(LOG_INFO,
                "Using synthetic passwd entry: "
                "name=%s uid=%lu gid=%lu home=%s shell=%s",
                pw->pw_name,
                (unsigned long)pw->pw_uid,
                (unsigned long)pw->pw_gid,
                pw->pw_dir,
                pw->pw_shell);

        return pw;
    }

    dropbear_log(LOG_WARNING,
            "No system or synthetic passwd entry for uid=%lu",
            (unsigned long)uid);

    return NULL;
}

/* END FlyThings passwd fallback */
