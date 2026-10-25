#!/usr/bin/env bash
# Pings local gateway and 8.8.8.8 and resolves a DNS name every 30s (override with
# NETCHECK_INTERVAL=seconds); logs results with timestamps.
# Usage: [NETCHECK_INTERVAL=10] ./netcheck.sh [logfile]

LOG="${1:-netcheck.log}"
GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway/ {print $2}')
INTERVAL="${NETCHECK_INTERVAL:-30}"
case "$INTERVAL" in ''|*[!0-9]*) echo "NETCHECK_INTERVAL must be a whole number of seconds" >&2; exit 1 ;; esac

if [ -z "$GATEWAY" ]; then
  echo "Could not detect default gateway" >&2
  exit 1
fi

echo "Logging to $LOG | gateway=$GATEWAY | external=8.8.8.8 | interval=$INTERVAL sec"
echo "Ctrl-C to stop."
echo "---" | tee -a "$LOG"

while true; do
  TS=$(date '+%Y-%m-%d %H:%M:%S')

  GW_RESULT=$(ping -c 1 -W 2000 "$GATEWAY" 2>&1 | awk -F'time=' '/time=/ {print $2; exit} END {if (!/time=/) print "FAIL"}')
  EXT_RESULT=$(ping -c 1 -W 2000 8.8.8.8 2>&1 | awk -F'time=' '/time=/ {print $2; exit} END {if (!/time=/) print "FAIL"}')
  DNS_RESULT=$(dig +short +time=2 +tries=1 cloudflare.com 2>/dev/null | head -1)
  [ -z "$DNS_RESULT" ] && DNS_RESULT="FAIL"

  LINE="[$TS] gw=$GW_RESULT  ext=$EXT_RESULT  dns=$DNS_RESULT"
  echo "$LINE" | tee -a "$LOG"

  sleep $INTERVAL
done
