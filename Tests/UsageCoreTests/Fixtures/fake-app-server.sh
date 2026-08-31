#!/bin/sh
while IFS= read -r line
do
  case "$line" in
    *'"method":"initialize"'*)
      printf '%s\n' '{"method":"remoteControl/status/changed","params":{"state":"idle"}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"codexHome":"/tmp/codex-home","platformFamily":"unix","platformOs":"macos","userAgent":"fake"}}'
      ;;
    *'"method":"account/rateLimits/read"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1788753600},"secondary":null},"rateLimitsByLimitId":null}}'
      printf '%s\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":31}}}}'
      ;;
    *'"method":"account/usage/read"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"summary":{"lifetimeTokens":1234,"peakDailyTokens":500,"longestRunningTurnSec":30,"currentStreakDays":2,"longestStreakDays":4},"dailyUsageBuckets":[{"startDate":"2026-08-30","tokens":400}]}}'
      ;;
  esac
done
