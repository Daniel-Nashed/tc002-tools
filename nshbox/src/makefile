TARGET  = nshbox

CROSS   = arm-linux-gnueabihf-
CC      = $(CROSS)gcc
READELF = $(CROSS)readelf

SRC     = nshbox.c

# -ffunction-sections/-fdata-sections + --gc-sections: the linker drops the
# parts of the static libraries (musl, mbedTLS) nshbox does not use.
CFLAGS  = -Os -Wall -Wextra -ffunction-sections -fdata-sections

# -lresolv: dig/nslookup use the C library's own stub resolver (res_query(),
# ns_initparse()/ns_parserr(), dn_expand()). musl has these inside libc
# (the -lresolv is then an empty stub); glibc keeps them in libresolv.
LDFLAGS = -Wl,--gc-sections -lresolv

# The sha256sum/sha1sum/sha384sum/sha512sum/md5sum commands use mbedTLS's
# low-level digest functions, always linked STATICALLY (libmbedcrypto.a), so
# the binary needs no crypto library on the device.
#
# MBEDTLS_DIR: prefix with include/ and lib/libmbedcrypto.a - the ARM build
# passes the mbedTLS this project builds itself (build/build_mbedtls.sh).
# Empty (the default) uses the system's libmbedtls-dev (-lmbedcrypto), which
# is what the native test containers has.
MBEDTLS_DIR =

# CHECKSUMS=0 leaves out those five commands (-DNSHBOX_NO_CHECKSUMS), so
# mbedTLS is not needed at all. Default is 1 (the normal build).
#
# STATIC=1 links everything statically, no shared libraries at all - a
# binary that can be copied to /tmp on any device and run regardless of the
# rootfs. Use TARGET=nshbox-static to build it beside the normal binary.
CHECKSUMS = 1
STATIC    = 0

ifeq ($(CHECKSUMS),0)
CFLAGS += -DNSHBOX_NO_CHECKSUMS
else
ifeq ($(MBEDTLS_DIR),)
# The archive's full path (not -lmbedcrypto), so the link is static whether
# or not the shared library is installed beside it, and STATIC=1 needs no
# -Bdynamic juggling. Prints just the bare name if it is not installed,
# which then fails the link with a clear "No such file" error.
LDFLAGS := $(shell $(CC) -print-file-name=libmbedcrypto.a) $(LDFLAGS)
else
CFLAGS  += -I$(MBEDTLS_DIR)/include
LDFLAGS := $(MBEDTLS_DIR)/lib/libmbedcrypto.a $(LDFLAGS)
endif
endif

ifeq ($(STATIC),1)
LDFLAGS := -static $(LDFLAGS)
endif

all: $(TARGET)

$(TARGET): $(SRC) version.h
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -o $@

install: $(TARGET)
	adb push $(TARGET) /data/$(TARGET)
	adb shell chmod +x /data/$(TARGET)

run: install
	adb shell /data/$(TARGET) $(ARGS)

test: install
	adb shell /data/$(TARGET) sysinfo
	adb shell /data/$(TARGET) netstat -l

clean:
	rm -f $(TARGET)

info: $(TARGET)
	file $(TARGET)
	ls -lh $(TARGET)
	$(READELF) -h $(TARGET) | grep -E 'Class:|Machine:'
	$(READELF) -d $(TARGET) | grep NEEDED || true

.PHONY: all install run test clean info
