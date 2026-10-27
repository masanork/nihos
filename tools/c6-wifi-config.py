#!/usr/bin/env python3
"""Generate a private Zig config; never echo SSID/password or hash credentials."""
import json
import os
from pathlib import Path
import stat
import sys


def main():
    destination = Path(sys.argv[1])
    source = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
    protocol = sys.argv[3] if len(sys.argv) > 3 else 'at'
    if protocol not in ('at', 'hosted'):
        raise ValueError('Unsupported C6 protocol')
    enabled, saved, ssid, password = source is not None, False, b'', b''
    if source is not None:
        if not source.is_file() or stat.S_IMODE(source.stat().st_mode) & 0o077:
            raise ValueError('Wi-Fi config must be a local file with mode 0600 or stricter')
        config = json.loads(source.read_text())
        if config == {'saved': True}:
            saved = True
        elif isinstance(config, dict) and set(config) == {'ssid', 'password'}:
            if not isinstance(config['ssid'], str) or not isinstance(config['password'], str):
                raise ValueError('SSID and password must be strings')
            ssid, password = config['ssid'].encode('utf-8'), config['password'].encode('utf-8')
            if not 1 <= len(ssid) <= 32 or len(password) > 63:
                raise ValueError('SSID/password length outside ESP-AT limits')
            if any(byte < 32 or byte == 127 for byte in ssid + password):
                raise ValueError('Control bytes are not allowed in credentials')
        else:
            raise ValueError('Use either saved:true or ssid/password fields')
    def array(value):
        return '[_]u8{' + ','.join(str(byte) for byte in value) + '}'
    text = (f'pub const enabled = {str(enabled).lower()};\n'
            f'pub const hosted = {str(protocol == "hosted").lower()};\n'
            f'pub const saved = {str(saved).lower()};\n'
            f'pub const ssid = {array(ssid)};\n'
            f'pub const password = {array(password)};\n')
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as output:
        os.fchmod(output.fileno(), 0o600)
        output.write(text)
    print('Wi-Fi config generated; enabled=' + str(enabled).lower() + '; credentials withheld')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, UnicodeError):
        # JSON exceptions and filesystem paths can contain secrets. Keep all
        # diagnostics deliberately generic and leave the config local.
        sys.exit('Invalid or unreadable private Wi-Fi configuration')
