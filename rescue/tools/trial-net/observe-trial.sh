#!/bin/sh
# Observe Phase-2 trial boot v4 (trial-9, NCM): poll BOTH rescue services — http and
# telnet — because E23: boot-time daemonized httpd could come up as a socketless CPU
# spinner while telnetd worked fine. Transports: WSL curl (may be NAT/firewall-limited),
# Windows curl.exe (direct via host NCM adapter), WSL bash /dev/tcp for port 23.
# Pins /run/stay over telnet when reachable so the device stays in Linux for live
# inspection (rescue path already ran restore_slot_a — staying is safe). When the device
# does roll back, verifies slot + misc.
cd /home/kk/code/zte7552n/changxing60-linux/work || exit 1
export PATH=/home/kk/code/zte7552n/rescue/bin:$PATH
WFETCH() { curl -s -m 2 --connect-timeout 1 "$1" -o "$2" 2>/dev/null; }
XFETCH() { /mnt/c/Windows/System32/curl.exe -s -m 2 "$1" -o "$2" 2>/dev/null; }
TPROBE() { timeout 2 bash -c 'exec 3<>/dev/tcp/192.168.77.1/23' 2>/dev/null; }
echo "[$(date +%T)] polling rescue net (http: WSL curl + Win curl.exe; telnet: /dev/tcp)..."
http=; tel=; telhits=0
i=1
while [ $i -le 100 ]; do
    if WFETCH http://192.168.77.1/ trial-index.html; then http=wsl; echo "[$(date +%T)] HTTPD UP via WSL curl after ~$((i*3))s"; break; fi
    if TPROBE; then
        tel=wsl; telhits=$((telhits+1))
        [ $telhits -eq 1 ] && echo "[$(date +%T)] TELNET UP (http not yet) after ~$((i*3))s"
        [ $telhits -ge 10 ] && { echo "[$(date +%T)] telnet up but httpd still dead after ~30s (E23 watchdog failed?)"; break; }
    fi
    if [ $((i % 3)) -eq 0 ] && XFETCH http://192.168.77.1/ trial-index.html; then http=win; echo "[$(date +%T)] HTTPD UP via Windows curl after ~$((i*3))s"; break; fi
    i=$((i+1)); sleep 2
done
[ -z "$http" ] && [ -z "$tel" ] && echo "[$(date +%T)] TIMEOUT: neither httpd nor telnet reachable"
[ -n "$http" ] && cat trial-index.html
if [ "$tel" = wsl ] || [ "$http" = wsl ]; then
    # Pin the session and grab live state over telnet
    python3 telnet-cmd.py 192.168.77.1 23 'touch /run/stay; echo STAY-OK' 'netstat -tln' 'ps | grep -E "httpd|telnetd|udhcpd" | grep -v grep' 'ifconfig usb0 | head -4' 'cat /run/udhcpd.leases; echo LEASES-END' 'dmesg | grep -E "usb0-stats|httpd-watchdog" | tail -4' 2>&1 | tee trial-telnet-live.txt
    echo "[$(date +%T)] LIVE: stay pinned — device stays in Linux; reboot -f via telnet when done"
fi
if [ "$http" = wsl ]; then
    WFETCH http://192.168.77.1/dmesg.txt trial-dmesg-live.txt && echo "[$(date +%T)] dmesg $(wc -c < trial-dmesg-live.txt) bytes"
    WFETCH http://192.168.77.1/modules.txt trial-modules.txt && echo "[$(date +%T)] modules loaded: $(grep -c . trial-modules.txt)"
elif [ "$http" = win ]; then
    XFETCH http://192.168.77.1/dmesg.txt trial-dmesg-live.txt && echo "[$(date +%T)] dmesg $(wc -c < trial-dmesg-live.txt) bytes (win)"
fi
if [ "$tel" = wsl ] || [ "$http" = wsl ]; then
    echo "[$(date +%T)] observation done (device pinned in Linux)"
    exit 0
fi
echo "[$(date +%T)] waiting for adb (auto-reboot ~300s uptime)..."
i=1
while [ $i -le 120 ]; do
    st=$(adb get-state 2>/dev/null | tr -d '\r')
    [ "$st" = device ] && { echo "[$(date +%T)] ADB BACK after ~$((i*3))s"; break; }
    i=$((i+1)); sleep 3
done
sleep 8
echo "[$(date +%T)] post-rollback verify:"
adb shell "getprop ro.boot.slot_suffix" 2>&1 | tr -d '\r'
adb shell "su -c 'dd if=/dev/block/by-name/misc bs=1 skip=2048 count=32 2>/dev/null | od -An -tx1 -v'" 2>&1 | tr -d '\r' | tr -s ' '
echo "[$(date +%T)] observation done"
