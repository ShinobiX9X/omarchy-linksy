#!/bin/bash
# The popup's actions. Each runs a `linksy` command and, when it fails, shows Linksy's own
# message as a notification instead of failing silently in the background.
#   actions.sh clip <device>          send this computer's clipboard text
#   actions.sh send <device>          pick files and send them
#   actions.sh files <device>         open the phone's files in the file manager
#   actions.sh ring <device> [--stop] make the phone ring, or stop it
device=$2

notify() {
  omarchy-notification-send -g "󰄜" "Linksy" "$1"
}

# Run linksy with the given arguments (stdin passes through); notify on failure
linksy_or_notify() {
  local out
  if ! out=$(linksy "$@" 2>&1); then
    notify "${out:-linksy $1 failed}"
    return 1
  fi
}

case $1 in
  clip)
    text=$(wl-paste --no-newline --type text 2>/dev/null)
    if [[ -z $text ]]; then
      notify "The clipboard holds no text"
      exit 1
    fi
    printf '%s' "$text" | linksy_or_notify clip "$device" && notify "Clipboard sent to the phone"
    ;;
  send)
    if ! command -v zenity >/dev/null; then
      notify "Sending files needs the zenity package. Install it, then try again."
      exit 1
    fi
    mapfile -t files < <(zenity --file-selection --multiple --separator=$'\n' --title="Send to phone" 2>/dev/null)
    ((${#files[@]})) || exit 0
    linksy_or_notify send "$device" "${files[@]}"
    ;;
  files)
    linksy_or_notify files "$device"
    ;;
  ring)
    linksy_or_notify ring "$device" ${3:+"$3"}
    ;;
esac
