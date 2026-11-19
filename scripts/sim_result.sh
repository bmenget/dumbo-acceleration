#!/usr/bin/env bash
# Summarize an LWC_TB run. LWC_TB writes result.txt like an exit code:
# "0" = pass; "1" = fail (preceded by "fail" once per failing word).
# Usage: sim_result.sh <simdir> <spec> <set>
dir=$1; spec=$2; set=$3

if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  G=$'\033[1;97;42m'; R=$'\033[1;97;41m'; Y=$'\033[1;30;43m'; Z=$'\033[0m'
else
  G=; R=; Y=; Z=
fi

banner() {  # color, label, detail lines...
  local c=$1 label=$2; shift 2
  echo
  echo "${c}  ==============  $label  ==============  ${Z}"
  for l in "$@"; do echo "  $l"; done
  echo
}

n_ok=$(grep -c "Started verifying MsgID" "$dir/sim.out" 2>/dev/null)
res=$({ tr -d '[:space:]' < "$dir/result.txt"; } 2>/dev/null)
case "$res" in
  0)  banner "$G" "PASS" "spec=$spec  set=$set  (${n_ok:-?} test vectors verified)" "$dir";;
  *1) first=$(head -1 "$dir/failed_test_vectors.txt" 2>/dev/null)
      banner "$R" "FAIL" "spec=$spec  set=$set" "${first:-see $dir/sim.out}" \
        "details: $dir/failed_test_vectors.txt"; exit 1;;
  *)  banner "$Y" "ERROR: no result written" "spec=$spec  set=$set" "see $dir/sim.out"; exit 1;;
esac
