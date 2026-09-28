#!/usr/bin/env bash
# Runs VillageManager against a fake village (tests/world.lua) - no game needed.
# Needs Lua 5.4 (e.g. `apt install lua5.4`).
#   ./tests/run_tests.sh            check against the saved expected results
#   ./tests/run_tests.sh --update   save the current results as the new expected ones
set -u
cd "$(dirname "$0")"
LUA=${LUA:-lua5.4}
fail=0

# The mod finds its data files with Windows paths ("Scripts\..\targets.txt").
# On Linux that is one literal file name, so stage copies under those names.
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Scripts"
cp ../VillageManager/Scripts/main.lua "$stage/Scripts/"
for f in targets.txt job_names.txt stacks.txt; do cp "../VillageManager/$f" "$stage/Scripts/..\\$f"; done

$LUA -v >/dev/null 2>&1 || { echo "Lua not found (set LUA=...)"; exit 1; }
luac5.4 -p ../VillageManager/Scripts/main.lua 2>/dev/null || $LUA -e "assert(loadfile('../VillageManager/Scripts/main.lua'))" || { echo "FAIL syntax"; exit 1; }
echo "ok   syntax"

# Stations the mod may change (section 1 of main.lua) plus the farm
MANAGED="8/9 8/10 8/8 9/13 9/14 10/11 10/12 6/17 3/1 3/2 3/3 3/4 3/5 3/6 3/7 7/15 7/16 11/21 1/9"

run() {  # name, env, check-totals(0/1), keys...   (WORLD=file picks the test village)
  local name=$1 envv=$2 checksum=$3; shift 3
  env $envv "$LUA" harness.lua "$stage/Scripts/main.lua" "${WORLD:-world.lua}" "$@" > "$stage/$name.out" 2>&1 || { echo "FAIL $name (crashed)"; cat "$stage/$name.out"; fail=1; return; }
  grep -qi "error" "$stage/$name.out" && { echo "FAIL $name (error in output)"; grep -i error "$stage/$name.out"; fail=1; }
  sed -n '/### FINAL FORCES/,$p' "$stage/$name.out" > "$stage/$name.final"
  if [ "${UPDATE:-0}" = 1 ]; then cp "$stage/$name.final" "expected_$name.txt"; echo "saved $name"; return; fi
  if diff -u "expected_$name.txt" "$stage/$name.final" > "$stage/$name.diff"; then echo "ok   $name matches expected result"
  else echo "FAIL $name differs from expected:"; cat "$stage/$name.diff"; fail=1; fi
  [ "$checksum" = 1 ] || return 0
  # Invariant: every station the mod manages adds up to 100% (or 0% = paused)
  awk -v managed="$MANAGED" 'BEGIN { n=split(managed,m," "); for (i=1;i<=n;i++) keep[m[i]]=1 }
       /^[0-9]+\/[0-9]+ job/ { split($1,a,"/"); key=a[1]"/"a[2]; if (!(key in keep)) next; sub("menu=","",$4); s[key]+=$4 }
       END { bad=0; for (k in s) if ((s[k]<0.99 || s[k]>1.01) && s[k]>0.001) { print "     station " k " sums to " s[k]; bad=1 } exit bad }' \
       "$stage/$name.final" && echo "ok   $name: every station adds up to 100% or is paused" || { echo "FAIL $name: station totals"; fail=1; }
}

[ "${1:-}" = "--update" ] && UPDATE=1
run plan_only   ""        0 NUM_ONE
run apply_twice ""        1 NUM_TWO NUM_TWO NUM_ONE
run hungry      HUNGRY=1  1 NUM_TWO NUM_TWO
# A brand-new village: different workplace numbers, unbuilt kitchen, no seeds
WORLD=world_fresh.lua run fresh_save "" 1 NUM_TWO NUM_TWO F9
WORLD=world_fresh_fed.lua run fresh_fed "" 1 NUM_TWO

[ $fail = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $fail
