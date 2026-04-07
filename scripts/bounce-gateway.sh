#!/bin/bash
pkill -f "nullclaw gateway" 2>/dev/null
sleep 1
nohup /home/yanggf/nullclaw/zig-out/bin/nullclaw gateway < /dev/null >> /home/yanggf/.nullclaw/gateway.log 2>&1 &
disown $!
sleep 2
tail -5 /home/yanggf/.nullclaw/gateway.log
