#!/usr/bin/env python3
"""Minimal one-shot telnet client for the rescue shell (busybox telnetd -l /bin/sh).
usage: telnet-cmd.py HOST PORT 'cmd1' 'cmd2' ...
Strips IAC negotiation, sends each command, prints the raw session response.
"""
import re
import socket
import sys
import time


def strip_iac(data: bytes) -> bytes:
    data = re.sub(rb'\xff\xfa.*?\xff\xf0', b'', data, flags=re.S)  # SB ... SE
    return re.sub(rb'\xff[\xfb-\xfe].', b'', data)                 # WILL/WONT/DO/DONT


def main() -> int:
    host, port = sys.argv[1], int(sys.argv[2])
    cmds = sys.argv[3:]
    s = socket.create_connection((host, port), timeout=5)
    s.settimeout(1.5)
    out = b''

    def drain():
        nonlocal out
        try:
            while True:
                d = s.recv(65536)
                if not d:
                    break
                out += d
        except socket.timeout:
            pass

    time.sleep(0.6)
    drain()  # banner + server-side negotiation (ignored; busybox tolerates silence)
    for c in cmds:
        s.sendall(c.encode() + b'\n')
        time.sleep(0.6)
        drain()
    s.close()
    sys.stdout.write(strip_iac(out).decode(errors='replace'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
