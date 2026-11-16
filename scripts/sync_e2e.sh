#!/bin/bash
# Two-instance sync check: runs two real Workday processes with separate temporary data folders and a shared
# temporary sync folder (not iCloud), drives them through the --e2e-control harness and checks they converge.
# Never touches the real data in ~/Library/Application Support/Workday.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Workday >/dev/null
BIN="$(swift build -c release --show-bin-path)/Workday"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/workday-e2e.XXXXXX")"
A="$TMP/a"; B="$TMP/b"; S="$TMP/sync"
mkdir -p "$A" "$B" "$S"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill -TERM "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

launch() { # dir name [args]
  local dir="$1" name="$2"; shift 2
  WORKDAY_DATA_DIR="$dir" WORKDAY_SYNC_DIR="$S" WORKDAY_SYNC_INTERVAL=1 WORKDAY_DEVICE_NAME="$name" \
    "$BIN" --e2e-control "$@" >"$dir.log" 2>&1 &
  PIDS+=($!)
}

# Waits until the Python expression holds for the instance state `s` (a dict); fails after 30 s.
wait_for() { # dir description expr
  local dir="$1" what="$2" expr="$3"
  for _ in $(seq 1 120); do
    if [[ -f "$dir/e2e-state.json" ]] && python3 -I -c "import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if ($expr) else 1)" "$dir/e2e-state.json" 2>/dev/null; then
      echo "  ✔ $what"; return 0
    fi
    sleep 0.25
  done
  echo "  ✘ $what"; cat "$dir/e2e-state.json" 2>/dev/null; echo; exit 1
}

cmd() { # dir command
  printf '%s' "$2" > "$1/e2e-command"
  wait_for "$1" "$(basename "$1"): $2" "s['result'] == 'ok: $2'"
}

field() { python3 -I -c "import json,sys; s=json.load(open(sys.argv[1])); print($2)" "$1/e2e-state.json"; }
same='lambda a, b: sorted((x["id"], x["start"], x["end"], x["state"]) for x in a["sessions"]) == sorted((x["id"], x["start"], x["end"], x["state"]) for x in b["sessions"])'
converged() { # description
  for _ in $(seq 1 120); do
    if python3 -I -c "import json,sys; same=$same; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); sys.exit(0 if same(a,b) and a['goalMinutes']==b['goalMinutes'] else 1)" "$A/e2e-state.json" "$B/e2e-state.json" 2>/dev/null; then
      echo "  ✔ converged: $1"; return 0
    fi
    sleep 0.25
  done
  echo "  ✘ not converged: $1"; exit 1
}

echo "Launching two instances (A seeded with demo history)…"
launch "$A" "Test Mac A" --seed-demo
launch "$B" "Test Mac B"
wait_for "$A" "A has demo history" "len(s['sessions']) > 20"
N="$(field "$A" "len(s['sessions'])")"
wait_for "$B" "B imported A's $N sessions" "len(s['sessions']) == $N and s['peers'] == ['Test Mac A']"
converged "initial merge"

echo "Timer: start on A, see it on B, take over on B, stop on B…"
cmd "$A" start
wait_for "$B" "B shows the timer running on Test Mac A" "s['runningElsewhere'] == ['Test Mac A'] and not s['running']"
cmd "$B" takeover
wait_for "$A" "A's timer stopped by B; A sees B running" "not s['running'] and s['runningElsewhere'] == ['Test Mac B']"
sleep 1.2
cmd "$B" stop
wait_for "$A" "A sees nothing running anywhere" "not s['running'] and s['runningElsewhere'] == []"
converged "after timer hand-over"

echo "Edits, deletes and settings…"
ID="$(field "$A" "[x for x in s['sessions'] if x['state']=='closed'][0]['id']")"
START="$(field "$A" "[x for x in s['sessions'] if x['id']=='$ID'][0]['start']")"
END="$(field "$A" "[x for x in s['sessions'] if x['id']=='$ID'][0]['end']")"
NEWSTART="$(python3 -c "print(int($START) + 600)")"
cmd "$A" "edit $ID $NEWSTART ${END%.*}"
wait_for "$B" "B sees A's edit" "[x for x in s['sessions'] if x['id']=='$ID'][0]['start'] == $NEWSTART"
cmd "$B" "delete $ID"
wait_for "$A" "A sees B's delete" "'$ID' not in [x['id'] for x in s['sessions']]"
cmd "$B" "goal 330"
wait_for "$A" "A sees B's goal change" "s['goalMinutes'] == 330"
converged "after edits"

echo "Sync folder layout and permissions…"
for d in "$A" "$B"; do
  dev="$(field "$d" "s['device']")"
  dir="$S/Workday Sync/devices/$dev"
  [[ -f "$dir/device.json" ]] || { echo "  ✘ missing $dir/device.json"; exit 1; }
  perms="$(stat -f %Lp "$dir")"; [[ "$perms" == 700 ]] || { echo "  ✘ $dir is $perms"; exit 1; }
done
echo "  ✔ one owner-only folder per device"
for d in "$A" "$B"; do
  wait_for "$d" "$(basename "$d") reports no sync problems" "s['syncStatus'] == 'ok' and s['problems'] == []"
done
echo "All two-instance sync checks passed."
