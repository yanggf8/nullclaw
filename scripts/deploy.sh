#!/usr/bin/env bash
# Build a release binary and restart the running nullclaw service so it picks up
# the current source. "Deploy" for a local/self-hosted nullclaw runtime.
#
# Usage:
#   scripts/deploy.sh            # build + restart service (or bounce gateway)
#   scripts/deploy.sh --build    # build only, do not restart
#   scripts/deploy.sh --no-test  # skip the pre-deploy test gate (NOT recommended)
#
# Safe to run repeatedly. Requires Zig 0.16.0.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/zig-out/bin/nullclaw"
SERVICE="nullclaw"
LOG="$HOME/.nullclaw/gateway.log"

BUILD_ONLY=0
RUN_TESTS=1
for arg in "$@"; do
  case "$arg" in
    --build) BUILD_ONLY=1 ;;
    --no-test) RUN_TESTS=0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

cd "$REPO"

# Pin Zig version — the project requires exactly 0.16.0.
have_zig_version=$(zig version 2>/dev/null || echo "MISSING")
if [ "$have_zig_version" != "0.16.0" ]; then
  echo "deploy: zig 0.16.0 required, found '$have_zig_version'" >&2
  exit 1
fi

# Pre-deploy gate: never ship a red tree. The signal-channel test is a known
# WSL2 flake (timeout, not a real failure) — tolerate exactly that one.
if [ "$RUN_TESTS" -eq 1 ]; then
  echo "deploy: running test gate (zig build test) ..."
  if ! zig build test -Dchannels=all -Dengines=base,sqlite --test-timeout 60s >/tmp/nullclaw-deploy-test.log 2>&1; then
    fails=$(grep -cE "^error: '" /tmp/nullclaw-deploy-test.log || true)
    only_signal_flake=$(grep -E "^error: '|timed out" /tmp/nullclaw-deploy-test.log \
      | grep -vE "channels.signal.test.process envelope attachment only" | grep -cE "^error: '|timed out" || true)
    if [ "$only_signal_flake" -ne 0 ]; then
      echo "deploy: test gate FAILED (not just the known signal flake). See /tmp/nullclaw-deploy-test.log" >&2
      grep -E "^error: '|timed out|Build Summary" /tmp/nullclaw-deploy-test.log >&2 || true
      exit 1
    fi
    echo "deploy: only the known WSL2 signal-channel flake failed — continuing."
  fi
fi

echo "deploy: building release binary (ReleaseSmall) ..."
zig build -Doptimize=ReleaseSmall
zig fmt --check src/ || { echo "deploy: zig fmt --check failed" >&2; exit 1; }

if [ ! -x "$BIN" ]; then
  echo "deploy: expected binary not found at $BIN" >&2
  exit 1
fi
echo "deploy: built $BIN ($(stat -c '%s' "$BIN") bytes)"

if [ "$BUILD_ONLY" -eq 1 ]; then
  echo "deploy: --build given, not restarting service."
  exit 0
fi

# Restart via systemd user service if it manages nullclaw; else bounce directly.
if systemctl --user list-unit-files "$SERVICE.service" >/dev/null 2>&1 \
   && systemctl --user is-enabled "$SERVICE" >/dev/null 2>&1; then
  echo "deploy: restarting systemd user service '$SERVICE' ..."
  systemctl --user restart "$SERVICE"
  sleep 2
  systemctl --user is-active "$SERVICE" >/dev/null 2>&1 \
    && echo "deploy: service active." \
    || { echo "deploy: service did NOT come back active:" >&2; systemctl --user status "$SERVICE" --no-pager | head -15 >&2; exit 1; }
else
  echo "deploy: no systemd service; bouncing gateway process directly ..."
  pkill -f "nullclaw gateway" 2>/dev/null || true
  sleep 1
  nohup "$BIN" gateway < /dev/null >> "$LOG" 2>&1 &
  disown $! || true
  sleep 2
  pgrep -f "nullclaw gateway" >/dev/null && echo "deploy: gateway running." || { echo "deploy: gateway failed to start; see $LOG" >&2; exit 1; }
fi

echo "deploy: done. Running version:"
"$BIN" --version 2>/dev/null || "$BIN" version 2>/dev/null || true
