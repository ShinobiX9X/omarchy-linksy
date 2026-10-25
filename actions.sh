#!/bin/bash
# Popup actions that need more than one `linksy` call.
#   actions.sh clip <device>   send this computer's clipboard text
#   actions.sh send <device>   pick files and send them
device=$2

case $1 in
  clip)
    text=$(wl-paste --no-newline --type text 2>/dev/null)
    if [[ -z $text ]]; then
      omarchy-notification-send -g "󰄜" "Linksy" "The clipboard holds no text"
      exit 1
    fi
    printf '%s' "$text" | linksy clip "$device" >/dev/null &&
      omarchy-notification-send -g "󰄜" "Linksy" "Clipboard sent to the phone"
    ;;
  send)
    if ! command -v zenity >/dev/null; then
      omarchy-notification-send -g "󰄜" "Linksy" "Sending files needs the zenity package. Install it, then try again."
      exit 1
    fi
    mapfile -t files < <(zenity --file-selection --multiple --separator=$'\n' --title="Send to phone" 2>/dev/null)
    ((${#files[@]})) || exit 0
    linksy send "$device" "${files[@]}" >/dev/null
    ;;
esac
