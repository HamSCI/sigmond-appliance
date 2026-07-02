#!/bin/bash
# qmp-type.sh <qmp-sock> <string...>   — type a string + Enter into the VM console
# via QMP sendkey. Requires socat. Handles a-z 0-9 and common punctuation.
SOCK="$1"; shift
TEXT="$*"
keyev(){ # emit one sendkey json for key (with optional shift)
  local k="$1" sh="${2:-0}"
  if [ "$sh" = 1 ]; then
    printf '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"shift"},{"type":"qcode","data":"%s"}]}}\n' "$k"
  else
    printf '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"%s"}]}}\n' "$k"
  fi
}
emit(){
  printf '{"execute":"qmp_capabilities"}\n'
  local i c
  for ((i=0; i<${#TEXT}; i++)); do
    c="${TEXT:$i:1}"
    case "$c" in
      [a-z]) keyev "$c";;
      [A-Z]) keyev "$(echo "$c" | tr A-Z a-z)" 1;;
      [0-9]) keyev "$c";;
      " ") keyev spc;;
      "-") keyev minus;;
      "_") keyev minus 1;;
      "/") keyev slash;;
      ".") keyev dot;;
      ",") keyev comma;;
      ":") keyev semicolon 1;;
      ";") keyev semicolon;;
      "=") keyev equal;;
      "|") keyev backslash 1;;
      "!") keyev 1 1;;
      "@") keyev 2 1;;
      "#") keyev 3 1;;
      "$") keyev 4 1;;
      "&") keyev 7 1;;
      "*") keyev 8 1;;
      "(") keyev 9 1;;
      ")") keyev 0 1;;
      "'") keyev apostrophe;;
      '"') keyev apostrophe 1;;
      ">") keyev dot 1;;
      "<") keyev comma 1;;
      "~") keyev grave_accent 1;;
    esac
    sleep 0.04
  done
  keyev ret
  sleep 0.2
}
emit | sudo socat -t2 - "unix-connect:$SOCK" >/dev/null
