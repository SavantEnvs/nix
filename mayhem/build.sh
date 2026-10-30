#!/usr/bin/env bash
# Builds, from /mayhem: (1) the sanitized libFuzzer harnesses fuzz-* and their *-standalone reproducers,
# (2) the unit-test binaries (normal flags) that mayhem/test.sh runs. Offline: every dependency lives in
# /opt/toolchains/nix-deps (mayhem/install-deps.sh) or apt.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

DEPS=/opt/toolchains/nix-deps
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" BOOST_ROOT="$DEPS" CMAKE_PREFIX_PATH="$DEPS"
# New-dtags RUNPATH is not transitive, so the boost libs' own boost deps would not resolve.
BASE_LDFLAGS="-Wl,--disable-new-dtags -L$DEPS/lib -Wl,-rpath,$DEPS/lib"
# Upstream links the sanitizer runtime shared (-shared-libasan); it lives in clang's resource dir.
ASAN_RPATH="-Wl,-rpath,$("$CC" -print-resource-dir)/lib/linux"

cd "$SRC"
FUZZ="$SRC/build/fuzz"
TEST="$SRC/build/test"
COMMON_OPTS=(-Dfunctional-tests=false -Djson-schema-checks=false -Dlibcmd:readline-flavor=readline -Dbuildtype=debugoptimized)

# 1) Sanitized project + harnesses (everything instrumented, DWARF 3).
CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
LDFLAGS="$BASE_LDFLAGS $ASAN_RPATH" \
  meson setup "$FUZZ" --reconfigure "${COMMON_OPTS[@]}" -Dfuzzers=true -Dunit-tests=false \
    -Db_sanitize=address,undefined,fuzzer-no-link -Db_lundef=false
HARNESSES=$(meson introspect "$FUZZ" --targets | jq -r '.[] | select(.name | startswith("fuzz-")) | .name')
# shellcheck disable=SC2086
ninja -C "$FUZZ" -j"$MAYHEM_JOBS" $(meson introspect "$FUZZ" --targets | jq -r '.[] | select(.name | startswith("fuzz-")) | .filename[0]' | sed "s#^$FUZZ/##")

# 2) Re-link each harness from meson's own link line: once with libFuzzer (+ lsan_off), once with the
#    run-once driver (+ lsan_off) as /mayhem/<harness>-standalone.
OBJ=/tmp/mayhem-objs
mkdir -p "$OBJ"
# shellcheck disable=SC2086
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
# shellcheck disable=SC2086
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
EXTRA_RPATH="-Wl,-rpath,$FUZZ/src/libutil -Wl,-rpath,$FUZZ/src/libstore"
for h in $HARNESSES; do
  rel=$(meson introspect "$FUZZ" --targets | jq -r --arg n "$h" '.[] | select(.name == $n) | .filename[0]' | sed "s#^$FUZZ/##")
  link=$(cd "$FUZZ" && ninja -t commands "$rel" | tail -1)
  # fuzz binary: same link line, new output path, lsan hook added
  (cd "$FUZZ" && eval "${link/-o $rel/-o $SRC/$h} $EXTRA_RPATH $OBJ/lsan_off.o")
  # standalone: drop libFuzzer, add the run-once main
  sa=${link//"-fsanitize=address,undefined,fuzzer "/"-fsanitize=address,undefined "}
  (cd "$FUZZ" && eval "${sa/-o $rel/-o $SRC/$h-standalone} $EXTRA_RPATH $OBJ/lsan_off.o $OBJ/standalone_main.o")
done

# 3) Unit tests with the project's normal flags (independent tree, no sanitizers).
CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$BASE_LDFLAGS $COVERAGE_FLAGS" \
  meson setup "$TEST" --reconfigure "${COMMON_OPTS[@]}" -Dunit-tests=true -Dfuzzers=false
ninja -C "$TEST" -j"$MAYHEM_JOBS" src/libutil-tests/nix-util-tests src/libstore-tests/nix-store-tests
