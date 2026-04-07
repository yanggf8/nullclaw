# Windows Task Scheduler entry point
# Trigger: At log on (or At startup)
# Action:  powershell.exe -WindowStyle Hidden -File "<path>\start-wsl-services.ps1"

wsl -d Ubuntu -u yanggf -- bash /home/yanggf/nullclaw/scripts/start-services.sh
