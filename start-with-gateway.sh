#!/usr/bin/env bash
set -u

for _ in 1 2 3; do
  hermes gateway run --accept-hooks &
  gateway_pid=$!

  sleep 5

  if kill -0 "$gateway_pid" 2>/dev/null; then
    break
  fi

  wait "$gateway_pid" 2>/dev/null || true
done

exec sleep infinity
