#!/usr/bin/env bash
# tools/coverage.sh — per-file coverage, with the "no spec at all" case made impossible to miss.
#
# luacov only reports files it saw LOADED. A module no spec ever requires is not 0% in its output --
# it is absent, which reads as nothing at all. That is the most dangerous case and the one this
# project keeps hitting (`tasks/lessons.md`: "A module with no spec ships bugs that read as correct
# code"). So the shipped file list is the source of truth here, and anything luacov did not see is
# reported as NEVER LOADED rather than quietly dropped.
#
#   make coverage             fail on any file no spec loads (default)
#   make coverage MIN=60      also fail any measured file below 60%
#
# Files that are legitimately not testable yet are declared in tools/coverage-exempt.txt WITH A
# REASON, so "not built yet" is a statement someone wrote down rather than a silence.
set -uo pipefail

MIN="${MIN:-0}"
LUA="${LUA:-lua5.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "$(basename "$0"): cannot cd to $ROOT" >&2; exit 2; }  # else: measuring the wrong tree
# luacov is typically a --local rock, so both the binary and the Lua module search paths need the
# user tree on them. PATH alone is not enough: busted's --coverage does require("luacov") in-process.
eval "$(luarocks path 2>/dev/null)" || true
export PATH="$HOME/.luarocks/bin:$PATH"

command -v luacov >/dev/null 2>&1 || {
  echo "coverage: luacov not found. Install with: luarocks install --local luacov"; exit 2; }

rm -f luacov.stats.out luacov.report.out
busted --lua="$LUA" --coverage tests/spec >/dev/null 2>&1 || {
  echo "coverage: the suite failed; coverage of a red suite means nothing."; exit 2; }
luacov >/dev/null 2>&1

EXEMPT="tools/coverage-exempt.txt"
is_exempt() { [ -f "$EXEMPT" ] && grep -qE "^$1([[:space:]]|$)" "$EXEMPT"; }

printf '%-46s %8s  %s\n' "FILE" "COVERAGE" "STATUS"
printf '%s\n' "----------------------------------------------------------------------------"

fail=0
while IFS= read -r f; do
  line="$(grep -F "$f " luacov.report.out | tail -1)"
  if [ -z "$line" ]; then
    if is_exempt "$f"; then
      printf '%-46s %8s  %s\n' "$f" "-" "exempt (declared)"
    else
      printf '%-46s %8s  %s\n' "$f" "0.00%" "NEVER LOADED BY ANY SPEC"
      fail=$((fail + 1))
    fi
    continue
  fi
  pct="$(printf '%s' "$line" | awk '{print $NF}' | tr -d '%')"
  if awk "BEGIN{exit !($pct <= 0)}"; then
    if is_exempt "$f"; then printf '%-46s %8s  %s\n' "$f" "0.00%" "exempt (declared)"
    else printf '%-46s %8s  %s\n' "$f" "0.00%" "NO LINE EVER EXECUTED"; fail=$((fail + 1)); fi
  elif awk "BEGIN{exit !($pct < $MIN)}"; then
    printf '%-46s %7s%%  %s\n' "$f" "$pct" "below MIN=$MIN"
    fail=$((fail + 1))
  else
    printf '%-46s %7s%%\n' "$f" "$pct"
  fi
done < <(find Elmira* -name '*.lua' -not -path '*/Libs/*' | sort)

echo
grep -E '^Total' luacov.report.out | tail -1
echo

if [ "$fail" -gt 0 ]; then
  echo "coverage: $fail file(s) below the floor."
  echo "A file no spec loads is not 'untested yet' -- it is a file where a wiring bug cannot be seen."
  echo "Either add a spec, or declare it in $EXEMPT with the reason it cannot have one."
  exit 1
fi
echo "coverage: every shipped file is exercised by at least one spec."
