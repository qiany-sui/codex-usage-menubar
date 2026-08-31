#!/bin/bash
case "$1" in
  response-exit)
    (sleep 0.05; printf '%s\n' 'response') &
    exit 0
    ;;
  stdout-eof)
    exec 1>&-
    sleep 2
    ;;
  delayed-nonzero-after-stdout-eof)
    exec 1>&-
    sleep 1
    exit 7
    ;;
  nonzero-exit)
    (sleep 0.05; printf '%s\n' 'response') &
    exit 7
    ;;
  start-marker)
    printf 'x' >> "$2"
    printf '%s\n' 'started'
    while IFS= read -r line
    do
      :
    done
    ;;
  exact-newline)
    IFS= read -r first || exit 2
    if IFS= read -r -t 0.3 second
    then
      printf '%s\n' 'extra-line'
    else
      printf 'single:%s\n' "$first"
    fi
    ;;
esac
