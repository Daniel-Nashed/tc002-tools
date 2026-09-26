#!/bin/sh
# A C compiler wrapper for nginx's cross-build ./configure (see
# build/build_nginx.sh, which passes this as --with-cc).
#
# nginx's configure compiles small test programs and RUNS them ("objs/autotest"),
# even with --crossbuild - impossible for an ARM binary on an x86 build host
# unless something emulates it. This wrapper compiles with the real
# cross-compiler, and then, ONLY for a test program named "autotest", replaces
# the executable with a tiny launcher script that runs it under qemu-arm
# (user-mode emulation, from the Alpine "qemu-arm" package) with the toolchain's
# own musl as its library root. Nothing has to be registered with the host
# kernel (no binfmt_misc, no --privileged container), and it works for both
# static and dynamic test programs.
#
# Every other compile and link - including the final "objs/nginx" - passes
# through untouched.
#
# Environment (set by build_nginx.sh):
#   QEMU_CC_REAL   the real cross-compiler, e.g. arm-linux-musleabihf-gcc
#   QEMU_SYSROOT   the toolchain's target sysroot (holds lib/ld-musl-armhf.so.1)

"${QEMU_CC_REAL:?QEMU_CC_REAL is not set}" "$@" || exit $?

out=""
prev=""
compile_only=0

for arg in "$@"
do
  if [ "$prev" = "-o" ]; then
    out="$arg"
  fi

  if [ "$arg" = "-c" ]; then
    compile_only=1
  fi

  prev="$arg"
done

if [ "$compile_only" -eq 0 ] && [ -n "$out" ] && [ "$(basename "$out")" = "autotest" ] && [ -f "$out" ]; then
  out_abs="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

  mv "$out_abs" "${out_abs}.arm"

  printf '#!/bin/sh\nexec qemu-arm -L "%s" "%s.arm" "$@"\n' "${QEMU_SYSROOT:?QEMU_SYSROOT is not set}" "$out_abs" > "$out_abs"

  chmod +x "$out_abs"
fi

exit 0
