#!/bin/bash
# Does this widget still fit the installed Linksy? Tests what the widget relies on:
# linksyd's socket and its `devices` reply, the event names it reacts to, and the
# `linksy` CLI commands its popup runs. The widget runs it (with --json --notify)
# whenever it meets a Linksy version it hasn't checked yet. It also warns, without
# failing, when other accounts can open Linksy's data folder.
#
#   check.sh            test and print the result (exit 0 = fits, 1 = changed, 2 = can't tell)
#   check.sh --json     print the result as one JSON object instead
#   check.sh --notify   also notify, once per Linksy version, when it doesn't fit
#   check.sh --cached   reuse this version's earlier result instead of testing again
#
# Results are kept per Linksy version in $XDG_STATE_HOME/<plugin id>/.

dir=$(cd "$(dirname "$0")" && pwd)
id=$(jq -r .id "$dir/manifest.json" 2>/dev/null)
state=${XDG_STATE_HOME:-$HOME/.local/state}/${id:-linksy-widget}
mkdir -p "$state"

json=false notify=false cached=false
for arg; do
  case $arg in
    --json) json=true ;;
    --notify) notify=true ;;
    --cached) cached=true ;;
    *) echo "usage: check.sh [--json] [--notify] [--cached]" >&2; exit 2 ;;
  esac
done

report() { # report <exit code> <version> <problem>...
  local code=$1 version=$2
  shift 2
  local result
  result=$(jq -cn --arg v "$version" --argjson code "$code" --argjson w "$(warnings_json)" '{version: $v, fits: ($code == 0), unknown: ($code == 2), problems: $ARGS.positional, warnings: $w}' --args "$@")
  ((code < 2)) && echo "$result" >"$state/result-$version.json"

  if $json; then
    echo "$result"
  elif ((code == 0)); then
    echo "The Linksy widget fits Linksy $version"
  elif ((code == 2)); then
    echo "Can't check the Linksy widget: $*"
  else
    echo "Linksy $version changed what the Linksy widget ($id) relies on:"
    printf '  - %s\n' "$@"
    echo "Update the widget with: omarchy plugin update $id"
    echo "No fix yet? Report it, with this list, where the widget came from (see its README)."
  fi
  if ! $json && ((${#warnings[@]})); then
    printf 'Warning: %s\n' "${warnings[@]}"
  fi

  if $notify && ((${#warnings[@]})) && [[ ! -f $state/warned ]]; then
    touch "$state/warned"
    omarchy-notification-send -g "󰄜" "Linksy's data folder is open to other accounts" \
      "Close it with: chmod 700 $data" >/dev/null 2>&1
  fi
  ((${#warnings[@]})) || rm -f "$state/warned"

  if $notify && ((code == 1)) && [[ $(cat "$state/notified" 2>/dev/null) != "$version" ]]; then
    echo "$version" >"$state/notified"
    omarchy-notification-send -u critical -g "󰄜" "Linksy $version changed what the Linksy widget relies on" \
      "$# change(s). Update the widget: omarchy plugin update $id" >/dev/null 2>&1
  fi
  exit "$code"
}

# Linksy keeps clipboard files from the phone and paired devices' keys in its data folder,
# with default permissions. Other accounts can open it when every folder on the way lets
# them through (o+x).
data=${XDG_DATA_HOME:-$HOME/.local/share}/linksy
warnings=()
if [[ -d $data ]]; then
  open=true path=$data
  while :; do
    (( 8#$(stat -c %a "$path") & 1 )) || { open=false; break; }
    [[ $path == / ]] && break
    path=$(dirname "$path")
  done
  $open && warnings+=("Other accounts on this computer can open Linksy's data folder ($data), with clipboard files from the phone and paired devices' keys. Close it with: chmod 700 $data")
fi
warnings_json() {
  ((${#warnings[@]})) || { echo '[]'; return; }
  jq -cn '$ARGS.positional' --args "${warnings[@]}"
}

command -v linksy >/dev/null || report 2 "" "Linksy isn't installed (no linksy command)"
version=$(linksy --version 2>/dev/null | awk 'NR==1 {print $2}')
[[ -n $version ]] || report 2 "" "linksy --version gave no version"

if $cached && [[ -f $state/result-$version.json ]]; then
  result=$(cat "$state/result-$version.json")
  mapfile -t problems < <(jq -r '.problems[]' <<<"$result")
  report "$(jq -r 'if .fits then 0 else 1 end' <<<"$result")" "$version" "${problems[@]}"
fi

problems=()

# The socket and the `devices` reply (the service may still be starting)
for _ in 1 2 3 4 5; do
  out=$(python3 -I - <<'EOF' 2>&1
import json, os, socket, sys
path = os.environ.get("LINKSY_SOCKET") or os.environ["XDG_RUNTIME_DIR"] + "/linksyd.sock"
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(path)
except OSError as e:
    print(f"RETRY can't reach linksyd at {path}: {e}"); sys.exit()
s.settimeout(5)
f = s.makefile("rw")

def call(i, cmd):
    f.write(json.dumps({"id": i, "cmd": cmd}) + "\n"); f.flush()
    while True:
        line = f.readline()
        if not line:
            raise EOFError("linksyd closed the socket")
        msg = json.loads(line)
        if msg.get("id") == i:
            return msg

bad = []
reply = call(1, "devices")
devices = reply.get("ok")
if not isinstance(devices, list):
    bad.append(f"`devices` doesn't answer with a list in \"ok\" (got: {json.dumps(reply)[:200]})")
else:
    for d in devices:
        for key, kind in (("connected", bool), ("trusted", bool), ("nearby", bool), ("device", dict)):
            if not isinstance(d.get(key), kind):
                bad.append(f"devices[].{key} is missing or not a {kind.__name__}")
        dev = d.get("device") or {}
        for key in ("id", "name", "kind"):
            if not isinstance(dev.get(key), str):
                bad.append(f"devices[].device.{key} is missing or not a string")
        b = d.get("battery")
        if b is not None and not (isinstance(b.get("level"), int) and isinstance(b.get("charging"), bool)):
            bad.append("devices[].battery isn't {level: int, charging: bool}")
for b in sorted(set(bad)):
    print("BAD " + b)
EOF
)
  grep -q '^RETRY' <<<"$out" || break
  sleep 2
done
while IFS= read -r line; do
  case $line in
    RETRY*) report 2 "$version" "${line#* }" ;;
    BAD*) problems+=("${line#* }") ;;
    "") ;;
    *) problems+=("socket test failed: $line") ;;
  esac
done <<<"$out"

# Event names the widget reacts to, as linksyd writes them
linksyd=$(command -v linksyd)
for name in transfer_progress transfer_complete transfer_failed; do
  grep -qa "$name" "$linksyd" || problems+=("linksyd no longer sends the \"$name\" event")
done

# CLI commands the popup runs
help=$(linksy --help 2>&1)
for cmd in "linksy ring <device> [--stop]" "linksy clip <device>" "linksy send <device>"; do
  grep -qF "$cmd" <<<"$help" || problems+=("\`linksy --help\` no longer lists \"$cmd\"")
done

((${#problems[@]} == 0)) && report 0 "$version"
report 1 "$version" "${problems[@]}"
