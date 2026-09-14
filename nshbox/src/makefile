TARGET  = nshbox

CROSS   = arm-linux-gnueabihf-
CC      = $(CROSS)gcc
READELF = $(CROSS)readelf

SRC     = nshbox.c

CFLAGS  = -Os -Wall -Wextra

# Dynamically linked against libcrypto: the sha256sum/sha1sum/sha512sum/md5sum
# commands use OpenSSL's EVP interface. The device needs libcrypto.so.1.1
# present at runtime as a result - see ../README.md for the size tradeoff
# (statically linking it pulled in well over 1MB from OpenSSL's own internal
# registration tables, for the same reason found and reversed in the
# now-merged standalone sha256sum tool this replaced).
#
# -lresolv: dig/nslookup use glibc's own stub resolver (res_query(),
# ns_initparse()/ns_parserr(), dn_expand()) - unlike libcrypto, this is
# not a separate optional package with its own version-matching risk;
# libresolv.so is an unconditional part of any glibc userland, the same
# guarantee libc.so.6 itself already carries.
LDFLAGS = -lcrypto -lresolv

all: $(TARGET)

$(TARGET): $(SRC)
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
