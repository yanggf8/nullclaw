#!/bin/bash
service ssh status || sudo service ssh start
tmux start-server 2>/dev/null
tmux has-session -t main 2>/dev/null || tmux new-session -d -s main
