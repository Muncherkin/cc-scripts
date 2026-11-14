#!/usr/bin/env bash
# The Mover hauls plain Factory Blocks from the chest station (beside the
# lift, site y 12-14, chests on the north wall at z -5) to the factory's
# input barrel: bridge/haul.sh [trips]. Each trip is up to 15 stacks.
# World coordinates below; the station's standing row is z 4750.
cd "$(dirname "$0")/.."
trips=${1:-6}
w() { node bridge/cli.js run worker "$@" --c 26 --timeout 300 2>&1 | head -1; }
chests="3544,12 3544,13 3544,14 3546,12 3546,14 3548,12 3548,13 3548,14 3550,12 3550,13 3550,14"
done_trips=0
for c in $chests; do
  x=${c%,*}; y=${c#*,}
  while [ "$done_trips" -lt "$trips" ]; do
    node bridge/mapworks.js goto "$x" "$y" 4750 | tail -1
    w face north
    took=$(w suck 15)
    echo "$(date -u +%T) chest $x $y: $took"
    case "$took" in "Took 0 "*|*error*|*Blocked*|"") break;; esac
    # In by the delivery lane: down the column west of the input, then east into it.
    node bridge/mapworks.js goto 3568 6 4765 | tail -1
    w go 3568 -12 4765
    w go 3568 -12 4764
    w face east
    echo "$(date -u +%T) $(w drop factory_blocks:factory)"
    w go 3567 -12 4764
    w go 3567 7 4764
    done_trips=$((done_trips + 1))
  done
done
echo "$(date -u +%T) hauled $done_trips trips"
