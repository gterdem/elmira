#!/usr/bin/env bash
# tools/selftest.sh — tests for the mutation gate itself.
#
# tools/mutants.sh decides whether every other check in this repo is trusted, and it has already
# shipped three defects that made it pass VACUOUSLY: a renamed spec, a dangling index entry and a
# missing luacov each turned real survivors into a green gate. A gate that cannot fail is worse than
# no gate, because it is mistaken for evidence. Nothing else in the repo covers tools/, so this does.
#
# Every case below is a real defect that was found by audit, encoded so it cannot come back. Runs
# entirely in a sandbox copy; the working tree is never touched.
set -uo pipefail

LUA="${LUA:-lua5.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "selftest: cannot cd to $ROOT" >&2; exit 2; }

command -v busted >/dev/null 2>&1 || { echo "selftest: busted not found"; exit 2; }
eval "$(luarocks path 2>/dev/null)" || true
export PATH="$HOME/.luarocks/bin:$PATH"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
cp -a "$ROOT/." "$SANDBOX/" 2>/dev/null
cd "$SANDBOX" || exit 2

# A small file keeps each case to a couple of seconds; the logic under test is the gate, not the file.
TARGET="Elmira/Core/Visibility.lua"
FAILED=0

verdict() { FILES="$TARGET" JOBS=4 ./tools/mutants.sh 2>&1; }

# Normalised as "<survivors>/<testable>", from EITHER report wording. Matching only the survivor
# branch would make every case below depend on the target file happening to have a survivor -- so
# closing that one gap in the suite would break the self-test rather than improve it.
normalise() {
  awk '
    /survivors of [0-9]+ testable/ { match($0, /of [0-9]+ testable/); t = substr($0, RSTART + 3, RLENGTH - 12); print "0/" t; exit }
    /[0-9]+ of [0-9]+ testable/    { match($0, /[0-9]+ of [0-9]+ testable/); split(substr($0, RSTART, RLENGTH), a, " "); print a[1] "/" a[3]; exit }
  '
}
survivors() { verdict | normalise; }

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
  else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; FAILED=$((FAILED + 1)); fi
}

echo "selftest: mutation gate, sandbox $SANDBOX"

# Ground truth, with the fast path warm. Everything after this must agree with it.
verdict >/dev/null 2>&1
BASE_VERDICT="$(survivors)"
[ -n "$BASE_VERDICT" ] || { echo "  FAIL  could not establish a baseline verdict"; exit 1; }
echo "  baseline: $BASE_VERDICT"

# 1. It must actually detect an unprotected line. A gate that never fails is the thing to fear.
cp -p "$TARGET" "$SANDBOX/st.bak"
{ head -1 "$TARGET"; printf 'local SELFTEST_UNPROTECTED = 1\n'; tail -n +2 "$TARGET"; } > "$SANDBOX/st.new"
cp "$SANDBOX/st.new" "$TARGET"
INJECTED="$(verdict | grep -cE '^  Elmira.*SELFTEST_UNPROTECTED|SELFTEST_UNPROTECTED')"
check "detects an injected unprotected line" "1" "$([ "$INJECTED" -ge 1 ] && echo 1 || echo 0)"
cp -p "$SANDBOX/st.bak" "$TARGET"

# 5. The equivalent-mutant hatch must demand a written reason. A bare marker, or the phrase inside a
#    string literal, previously exempted a line with no justification at all.
verdict >/dev/null 2>&1
LINE="$(grep -n '^local' "$TARGET" | head -1 | cut -d: -f1)"
cp -p "$TARGET" "$SANDBOX/st.bak"
sed -i "${LINE}s|\$| -- mutants: equivalent|" "$TARGET"
check "a bare 'mutants: equivalent' does NOT exempt" "$BASE_VERDICT" "$(survivors)"
cp -p "$SANDBOX/st.bak" "$TARGET"
BEFORE_TESTABLE="$(survivors | cut -d/ -f2)"
sed -i "${LINE}s|\$| -- mutants: equivalent because the reason goes here|" "$TARGET"
check "'mutants: equivalent <reason>' is reported as exempted" "1" \
  "$(verdict | grep -c "marked 'mutants: equivalent'" | head -1)"
# The message alone is not evidence: without the `continue` the line is counted as exempt AND still
# mutated, so the hatch silently stops working while the output still says it worked.
check "an exempted line is removed from the testable count" \
  "$((BEFORE_TESTABLE - 1))" "$(survivors | cut -d/ -f2)"
cp -p "$SANDBOX/st.bak" "$TARGET"

# 6. An already-red suite must abort. Otherwise every mutation "fails" and every line looks protected.
cp -p tests/spec/visibility_spec.lua "$SANDBOX/st.spec.bak"
printf '\ndescribe("selftest", function() it("red", function() assert.is_true(false) end) end)\n' \
  >> tests/spec/visibility_spec.lua
check "a red baseline aborts instead of reporting" "1" \
  "$(verdict | grep -c 'FAILS before any mutation' | head -1)"
# Asserting the message but not the status is exactly the hole that let `exit 1` -> `exit 0` through.
if FILES="$TARGET" JOBS=4 ./tools/mutants.sh >/dev/null 2>&1; then STATUS=0; else STATUS=$?; fi
check "a red baseline exits 2, not 0" "2" "$STATUS"
cp -p "$SANDBOX/st.spec.bak" tests/spec/visibility_spec.lua

# 7. The tree must come back byte-identical. Checking only for "-- MUTANT" residue could not fail,
#    because mutants.sh edits its own copy under $TMPDIR and never writes here at all -- so it would
#    have passed even if the script had corrupted every source file in some other way.
BEFORE_SUM="$(find Elmira* tests -name '*.lua' -exec cksum {} + | sort | cksum)"
verdict >/dev/null 2>&1
check "leaves the tree byte-identical" "$BEFORE_SUM" \
  "$(find Elmira* tests -name '*.lua' -exec cksum {} + | sort | cksum)"

# 8. The EXIT STATUS is the only thing CI consumes. Every case above reads stdout, so flipping
#    `exit 1` to `exit 0` disarmed the gate completely while this file still reported success --
#    survivors printed, build green. Assert both directions: survivors must fail the run, and a run
#    with nothing to check must not.
{ head -1 "$TARGET"; printf 'local SELFTEST_STATUS_CHECK = 1\n'; tail -n +2 "$TARGET"; } > "$SANDBOX/st.new"
cp "$SANDBOX/st.new" "$TARGET"
if FILES="$TARGET" JOBS=4 ./tools/mutants.sh >/dev/null 2>&1; then STATUS=0; else STATUS=1; fi
check "a survivor makes the gate EXIT NONZERO" "1" "$STATUS"
cp -p "$SANDBOX/st.bak" "$TARGET"

if FILES="" BASE=HEAD JOBS=4 ./tools/mutants.sh >/dev/null 2>&1; then STATUS=0; else STATUS=1; fi
check "a run with nothing to check exits ZERO" "0" "$STATUS"


# 8. tools/coverage.sh is a gate too, and until now nothing tested it: nulling its shipped-file
#    enumeration made the loop body never run, so it printed "every shipped file is exercised" and
#    exited 0 having checked nothing. Prove it actually notices a file no spec loads.
# toc_spec requires every Core/Adapters/Display/Options source to be listed in the TOC, so a bare
# new file makes the SUITE red and both gates abort -- which would let this case "pass" for entirely
# the wrong reason. Register it properly, before Core\\Init.lua, which must stay last.
addTempSource() { # <basename>
  printf 'local ADDON, ns = ...\nlocal T = 1\nreturn T\n' > "Elmira/Core/$1.lua"
  sed -i "s|^Core\\\\Init.lua$|Core\\\\$1.lua\nCore\\\\Init.lua|" Elmira/Elmira_Vanilla.toc
}
rmTempSource() { rm -f "Elmira/Core/$1.lua"; sed -i "/^Core\\\\$1.lua$/d" Elmira/Elmira_Vanilla.toc; }

addTempSource Unreached
if ./tools/coverage.sh >/dev/null 2>&1; then STATUS=0; else STATUS=1; fi
check "coverage notices a file no spec loads (exit nonzero)" "1" "$STATUS"
check "coverage names it" "1" \
  "$(./tools/coverage.sh 2>&1 | grep -c 'Unreached.lua.*NEVER LOADED')"
rmTempSource Unreached

# 9. A brand-new file is untracked, so `git diff` cannot see it -- and it is precisely where untested
#    code arrives. That target path had no case, so disabling it left every gate self-test green.
addTempSource BrandNew
sed -i 's|^local T = 1$|local BRANDNEW = 1|' Elmira/Core/BrandNew.lua
check "an untracked new file is mutated, not skipped" "1" \
  "$(BASE=HEAD JOBS=4 ./tools/mutants.sh 2>&1 | grep -c 'BRANDNEW')"
rmTempSource BrandNew

echo
if [ "$FAILED" -gt 0 ]; then echo "selftest: $FAILED case(s) FAILED"; exit 1; fi
echo "selftest: all cases passed"
