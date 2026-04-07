#!/bin/bash
# WSL service startup: sshd + ollama + nullclaw gateway
# Called by Windows Task Scheduler on login via start-wsl-services.ps1

LOG="$HOME/.nullclaw/startup.log"
mkdir -p "$HOME/.nullclaw"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

log "=== startup begin ==="

# sshd
if ! pgrep -x sshd > /dev/null; then
    sudo /usr/sbin/sshd
    log "sshd started"
else
    log "sshd already running"
fi

# ollama
if ! pgrep -x ollama > /dev/null; then
    nohup /usr/local/bin/ollama serve < /dev/null >> "$HOME/.nullclaw/ollama.log" 2>&1 &
    disown $!
    log "ollama started (pid $!)"
else
    log "ollama already running"
fi

# nullclaw gateway (wait for ollama to be ready)
if ! pgrep -f "nullclaw gateway" > /dev/null; then
    for i in $(seq 1 10); do
        if curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    nohup /home/yanggf/nullclaw/zig-out/bin/nullclaw gateway < /dev/null >> "$HOME/.nullclaw/gateway.log" 2>&1 &
    disown $!
    log "nullclaw gateway started (pid $!)"
else
    log "nullclaw gateway already running"
fi

log "=== startup done ==="
