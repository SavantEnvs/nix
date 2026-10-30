#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Runs nix's own gtest suites (libutil + libstore), built by mayhem/build.sh with normal flags. Each test
# asserts known-input -> known-output behavior (store paths, hashes, derivation/NAR/URL parsing, ...).
# Excluded: (1) boost-context's forced-unwind tests, which fail on boost 1.90 (fixed in 1.91, but 1.91 in
# turn breaks several boost.url based tests) — a toolchain regression, not project behavior; (2) the
# RootDeletePath.* tests, which assert geteuid()==0 and upstream runs separately as root.
EXCLUDE='-*forcedUnwind*:RootDeletePath.*'
BUILD="$SRC/build/test"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0; skipped=0
run_suite() {  # <binary> <data dir>
  local bin="$1" data="$2" json="$WORK/$(basename "$1").json"
  [ -x "$bin" ] || { echo "missing test runner $bin (build.sh should have built it)" >&2; failed=$((failed + 1)); return; }
  mkdir -p "$WORK/home"
  HOME="$WORK/home" NIX_REMOTE="$WORK/home/store" _NIX_TEST_UNIT_DATA="$data" \
    "$bin" --gtest_filter="$EXCLUDE" --gtest_output="json:$json" > "$WORK/$(basename "$bin").log" 2>&1
  tail -5 "$WORK/$(basename "$bin").log"
  if [ ! -s "$json" ]; then failed=$((failed + 1)); return; fi
  local counts
  counts=$(jq -r '[.testsuites[].testsuite[]] as $t
    | [ ($t | map(select(.result == "COMPLETED" and (has("failures") | not))) | length),
        ($t | map(select(.result == "COMPLETED" and has("failures"))) | length),
        ($t | map(select(.result == "SKIPPED")) | length) ] | @tsv' "$json")
  read -r p f s <<< "$counts"
  passed=$((passed + p)); failed=$((failed + f)); skipped=$((skipped + s))
}

run_suite "$BUILD/src/libutil-tests/nix-util-tests" "$SRC/src/libutil-tests/data"
run_suite "$BUILD/src/libstore-tests/nix-store-tests" "$SRC/src/libstore-tests/data"

# A run that parsed no tests proves nothing (a no-op runner must not pass).
[ "$passed" -gt 0 ] || failed=$((failed + 1))
emit_ctrf "gtest" "$passed" "$failed" "$skipped"
