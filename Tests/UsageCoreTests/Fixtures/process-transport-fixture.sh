#!/bin/bash
case "$1" in
  response-exit)
    printf '%s\n' 'response'
    ;;
  stdout-eof)
    exec 1>&-
    sleep 2
    ;;
  nonzero-exit)
    printf '%s\n' 'response'
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
