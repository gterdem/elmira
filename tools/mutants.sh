#!/usr/bin/env bash
# tools/mutants.sh — the mutation gate.
#
# This project's characteristic defect is a line you can delete with the whole suite still green: a
# function with a spec and no call site, a field read nothing writes, a guard that guards nothing.
# Lint cannot see it and neither can reading, because the code is correct -- it is simply unreached.
# So this asks the only question that separates tested from merely covered:
#
#     if I delete this line, does any test fail?
#
# A line that survives deletion is not protected by the suite. That is a finding, not a warning.
#
# It is affordable here because the suite runs in well under a second; most projects cannot gate a
# commit on this. Nothing is ever mutated in the real working tree -- every run happens in a throwaway
# copy under $TMPDIR, so an interrupted run cannot leave a half-mutated source file behind.
#
#   make mutants                  changed lines vs HEAD (what a pre-commit run wants)
#   make mutants BASE=HEAD~3      changed lines vs another revision
#   make mutants FILES="a.lua b"  those files, every line
#   make mutants ALL=1            every line of every shipped .lua -- slow, for a periodic sweep
#   make mutants JOBS=8           parallel workers (default: every hardware thread)
#
# Deliberately has no cache, no index and no fast path -- see ADR-0012 before adding one.
set -uo pipefail

BASE="${BASE:-HEAD}"
ALL="${ALL:-}"
FILES="${FILES:-}"
# Default to EVERY hardware thread, not half of them. Each worker copies a ~4MB tree once and
# then runs the suite per mutant, so this is CPU-bound with a negligible memory cost -- half
# the cores left half the machine idle for the slowest gate in the project. Override with JOBS=.
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
LUA="${LUA:-lua5.1}"
# A mutation can turn a loop condition into an infinite loop; without this the gate hangs instead of
# reporting.
TIMEOUT="${MUTANT_TIMEOUT:-60}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "$(basename "$0"): cannot cd to $ROOT" >&2; exit 2; }  # else: mutating the wrong tree, or reporting a vacuous pass from an empty file list

# Shipped Lua only. Libs/ is vendored, tests/ is the oracle -- mutating either measures nothing.
shipped_files() {
  find Elmira* -name '*.lua' -not -path '*/Libs/*' 2>/dev/null | sort
}

# --- target selection -------------------------------------------------------------------------
# Emits "file:line" pairs. Blank lines and whole-line comments are skipped: deleting them is not a
# behaviour change, so a survivor there would be noise, and noise is what makes a gate get ignored.
targets() {
  local files
  if [ -n "$FILES" ]; then
    files="$FILES"
  elif [ -n "$ALL" ]; then
    files="$(shipped_files)"
  else
    # -U0 so every hunk's new-side range IS the set of added lines, with no context to subtract.
    git diff -U0 "$BASE" -- 'Elmira*' 2>/dev/null | awk '
      /^\+\+\+ b\// { f = substr($0, 7); next }
      /^@@/ {
        if (f !~ /\.lua$/ || f ~ /\/Libs\//) next
        match($0, /\+[0-9]+(,[0-9]+)?/)
        spec = substr($0, RSTART + 1, RLENGTH - 1)
        n = split(spec, a, ",")
        start = a[1] + 0; count = (n > 1 ? a[2] + 0 : 1)
        for (i = 0; i < count; i++) print f ":" (start + i)
      }' > "$WORKDIR/diff_targets"
    # A file added but not yet `git add`ed has no diff at all, so every line of it would go unchecked
    # -- and a brand-new file is precisely where untested code arrives.
    git ls-files --others --exclude-standard -- 'Elmira*' 2>/dev/null \
      | grep -E '\.lua$' | grep -v '/Libs/' | while IFS= read -r nf; do
          [ -f "$nf" ] && seq 1 "$(wc -l < "$nf")" | sed "s|^|$nf:|"
        done >> "$WORKDIR/diff_targets"
    filter_lines < "$WORKDIR/diff_targets"
    return
  fi

  local f n
  for f in $files; do
    [ -f "$f" ] || continue
    n=$(wc -l < "$f")
    seq 1 "$n" | sed "s|^|$f:|"
  done | filter_lines
}

filter_lines() {
  local t f l text
  while IFS= read -r t; do
    f="${t%:*}"; l="${t##*:}"
    [ -f "$f" ] || continue
    # Blank or whole-line comment once leading whitespace is stripped.
    text="$(sed -n "${l}p" "$f" | sed 's/^[[:space:]]*//')"
    case "$text" in
      ''|--*) continue ;;
    esac
    # Escape hatch for a genuine EQUIVALENT MUTANT -- a line whose deletion cannot change behaviour,
    # so no test could ever catch it (Lua's implicit nil return is the usual source). Without this the
    # first such line blocks CI forever and the gate gets switched off, which is how gates die. The
    # marker must carry a reason on the same line, so it stays an argument someone made rather than a
    # silent opt-out, and `grep -rn "mutants: equivalent"` lists every one for review.
    # Must be an actual comment AND carry a reason after the marker. Quoted spans are stripped first,
    # so the phrase inside a Lua string literal cannot exempt a line -- a bare marker, or one hidden in
    # a string, previously suppressed a line with no justification at all.
    if printf '%s' "$text" | sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g" \
       | grep -qE -- '--[[:space:]]*mutants:[[:space:]]*equivalent[[:space:]]+[^[:space:]]'; then
      printf '%s\n' "$t" >> "$WORKDIR/exempt"
      continue
    fi
    printf '%s\n' "$t"
  done
}

# --- no spec selection, deliberately -----------------------------------------------------------
# Running only the specs that load the mutated file was built and removed the same day: it saved 1.6s
# on 16 cores and cost 89 lines and three vacuous-pass defects. ADR-0012 records why, and this comment
# exists so the next reader reaches the ADR before rebuilding it. Every mutation runs the whole suite.

# --- worker -----------------------------------------------------------------------------------
# Each worker owns a private copy of the tree, so mutations never race and never touch $ROOT.
run_worker() {
  local id="$1" list="$2" out="$3" work
  work="$WORKDIR/w$id"
  if ! cp -a "$ROOT/." "$work/" 2>/dev/null; then
    echo "mutants: worker $id could not copy the tree" >> "$WORKDIR/fatal"; return 1
  fi
  # A worker whose copy is broken fails every mutant, which reads as every line being protected.
  # Prove the copy is green before trusting a single result from it.
  if ! (cd "$work" && timeout "$TIMEOUT" busted --lua="$LUA" tests/spec >/dev/null 2>&1); then
    echo "mutants: worker $id's copy fails the suite unmutated" >> "$WORKDIR/fatal"; return 1
  fi

  local t f l orig
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    f="${t%:*}"; l="${t##*:}"
    orig="$(sed -n "${l}p" "$work/$f")"
    # Comment the line out rather than deleting it, so line numbers below it do not shift -- a shifted
    # error message points at the wrong line and makes every survivor harder to read.
    sed -i "${l}s|^|-- MUTANT |" "$work/$f"
    # Commenting out one line of a multi-line expression leaves a file that will not parse. The suite
    # then fails for a reason that has nothing to do with any test, and counting that as "caught"
    # would overstate what this gate proves -- across this tree it is ~40% of all lines. Report those
    # separately as skipped, so the protected count means only what it says.
    if "$LUA" -e "local f = loadfile('$work/$f'); os.exit(f and 0 or 1)" >/dev/null 2>&1; then
      # The whole suite, every time. Running only the specs that load the mutated file was tried and
      # removed the same day (ADR-0012): it saved ~1.6s on a 16-core machine and cost 89 lines of
      # index and staleness handling, in the one component nothing else covers -- three separate
      # defects in it made the gate report a VACUOUS PASS. `--no-keep-going` stops at the first
      # failure, which is the whole speedup that is free of state.
      if (cd "$work" && timeout "$TIMEOUT" busted --lua="$LUA" --no-keep-going tests/spec >/dev/null 2>&1); then
        printf '%s\t%s\n' "$t" "$orig" >> "$out"    # suite still green: the line is unprotected
      fi
    else
      printf '%s\n' "$t" >> "$WORKDIR/skipped"
    fi
    sed -i "${l}s|^-- MUTANT ||" "$work/$f"
  done < "$list"
}

# --- main -------------------------------------------------------------------------------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

targets > "$WORKDIR/targets"
TOTAL=$(wc -l < "$WORKDIR/targets" | tr -d ' ')

if [ "$TOTAL" -eq 0 ]; then
  echo "mutants: no candidate lines (base=$BASE). Nothing changed, or only comments changed."
  exit 0
fi

# A baseline that is already red makes every mutation look "caught". Fail loudly instead of
# reporting a clean sweep that means nothing.
if ! busted --lua="$LUA" tests/spec >/dev/null 2>&1; then
  echo "mutants: the suite FAILS before any mutation. Fix that first -- results would be meaningless."
  exit 2
fi

echo "mutants: $TOTAL line(s), $JOBS worker(s), base=$BASE"
split -n "l/$JOBS" -d "$WORKDIR/targets" "$WORKDIR/chunk" 2>/dev/null || cp "$WORKDIR/targets" "$WORKDIR/chunk00"

i=0
for chunk in "$WORKDIR"/chunk*; do
  mkdir -p "$WORKDIR/w$i"
  run_worker "$i" "$chunk" "$WORKDIR/survivors" &
  i=$((i + 1))
done
wait

if [ -f "$WORKDIR/fatal" ]; then
  cat "$WORKDIR/fatal"; echo "mutants: results would be meaningless; aborting."; exit 2
fi

EXEMPT=0
[ -f "$WORKDIR/exempt" ] && EXEMPT=$(wc -l < "$WORKDIR/exempt" | tr -d ' ')
SURV=0; SKIP=0
[ -f "$WORKDIR/survivors" ] && SURV=$(wc -l < "$WORKDIR/survivors" | tr -d ' ')
[ -f "$WORKDIR/skipped" ] && SKIP=$(wc -l < "$WORKDIR/skipped" | tr -d ' ')
TESTED=$((TOTAL - SKIP))

echo
if [ "$SURV" -eq 0 ]; then
  echo "mutants: 0 survivors of $TESTED testable line(s) — each is protected by a test."
  [ "$SKIP" -gt 0 ] && echo "         ($SKIP line(s) skipped: commenting them out does not parse, so nothing was proven)"
  [ "$EXEMPT" -gt 0 ] && echo "         ($EXEMPT line(s) marked 'mutants: equivalent' — grep for it to review them)"
  exit 0
fi

echo "mutants: $SURV of $TESTED testable line(s) SURVIVED deletion — no test failed without them:"
[ "$SKIP" -gt 0 ] && echo "         ($SKIP of $TOTAL skipped: commenting them out does not parse)"
[ "$EXEMPT" -gt 0 ] && echo "         ($EXEMPT line(s) marked 'mutants: equivalent' — grep for it to review them)"
echo
sort "$WORKDIR/survivors" | while IFS=$'\t' read -r loc src; do
  printf '  %s\n      %s\n' "$loc" "$(printf '%s' "$src" | sed 's/^[[:space:]]*//')"
done
echo
echo "Each is a line the suite does not actually check. Either it needs a test, or it is dead."
exit 1
