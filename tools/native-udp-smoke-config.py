#!/usr/bin/env python3
"""Append an opt-in private UDP peer to a private native configuration."""
import ipaddress
import json
import os
from pathlib import Path
import stat
import sys


def main():
    destination, source = map(Path, sys.argv[1:3])
    if not source.is_file() or stat.S_IMODE(source.stat().st_mode) & 0o077:
        raise ValueError('private peer required')
    data = json.loads(source.read_text())
    if not isinstance(data, dict) or not ({'ip', 'mac', 'port'} <= set(data) <= {'ip', 'mac', 'port', 'bssid'}):
        raise ValueError('invalid peer')
    if not isinstance(data['ip'], str) or not isinstance(data['mac'], str) or type(data['port']) is not int:
        raise ValueError('invalid peer')
    ip = ipaddress.IPv4Address(data['ip'])
    parts = data['mac'].split(':')
    if len(parts) != 6 or any(len(p) != 2 for p in parts):
        raise ValueError('invalid peer')
    mac = bytes(int(part, 16) for part in parts)
    if (ip.is_multicast or ip.is_unspecified or ip.is_loopback or ip.is_link_local or
            int(ip) == 0xffffffff or mac[0] & 1 or mac == bytes(6) or not 1 <= data['port'] <= 65535):
        raise ValueError('invalid peer')
    bssid = bytes(6)
    if 'bssid' in data:
        if not isinstance(data['bssid'], str):
            raise ValueError('invalid BSSID')
        parts = data['bssid'].split(':')
        if len(parts) != 6 or any(len(p) != 2 for p in parts):
            raise ValueError('invalid BSSID')
        bssid = bytes(int(part, 16) for part in parts)
        if bssid[0] & 1 or bssid == bytes(6):
            raise ValueError('invalid BSSID')
    text = ('pub const udp_smoke_bssid = [_]u8{' + ','.join(str(x) for x in bssid) + '};\n'
            + 'pub const udp_smoke_ip = [_]u8{' + ','.join(str(x) for x in ip.packed) + '};\n'
            + 'pub const udp_smoke_mac = [_]u8{' + ','.join(str(x) for x in mac) + '};\n'
            + f"pub const udp_smoke_port: u16 = {data['port']};\n")
    fd = os.open(destination, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
    with os.fdopen(fd, 'a') as output:
        os.fchmod(output.fileno(), 0o600)
        output.write(text)
    print('UDP smoke peer configured; details withheld')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, UnicodeError, TypeError):
        sys.exit('Invalid or unreadable private UDP smoke peer')
