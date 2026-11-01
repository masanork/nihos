#!/usr/bin/env python3
"""Generate a private Zig config; never echo SSID/password or hash credentials."""
import json
import ipaddress
import os
from pathlib import Path
import stat
import sys


def main():
    destination = Path(sys.argv[1])
    source = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
    protocol = sys.argv[3] if len(sys.argv) > 3 else 'at'
    ipv6 = os.environ.get('NIHOS_C6_IPV6', '0')
    long_dma = os.environ.get('NIHOS_C6_LONG_DMA', '0')
    udp_burst = os.environ.get('NIHOS_C6_UDP_BURST', '0')
    udp_burst_count = int(os.environ.get('NIHOS_C6_UDP_BURST_COUNT', '16'))
    udp_tail_short = os.environ.get('NIHOS_C6_UDP_TAIL_SHORT', '0')
    udp_pause_after_16 = os.environ.get('NIHOS_C6_UDP_PAUSE_AFTER_16', '0')
    udp_reverse = os.environ.get('NIHOS_C6_UDP_REVERSE', '0')
    udp_interval_ms = int(os.environ.get('NIHOS_C6_UDP_INTERVAL_MS', '250'))
    udp_audit_staging = os.environ.get('NIHOS_C6_UDP_AUDIT_STAGING', '0')
    if udp_pause_after_16 not in ('0', '1') or (udp_pause_after_16 == '1') != (udp_burst_count == 17):
        raise ValueError('Pause requires exactly 17 packets')
    if udp_burst_count not in (16, 17, 18) or (udp_burst_count != 16 and udp_burst != '1'):
        raise ValueError('UDP burst count must be 16, 17, or 18 in burst mode')
    if udp_tail_short not in ('0', '1') or (udp_tail_short == '1' and (udp_burst != '1' or udp_burst_count != 16)):
        raise ValueError('Short tail requires a 16-packet burst')
    if udp_reverse not in ('0', '1') or (udp_reverse == '1' and (udp_burst != '1' or udp_burst_count != 16 or udp_tail_short != '0')):
        raise ValueError('Reverse requires a plain 16-packet burst')
    if udp_interval_ms not in (250, 500) or (udp_interval_ms != 250 and (udp_burst != '1' or udp_burst_count != 16 or udp_tail_short != '0' or udp_reverse != '0')):
        raise ValueError('Extended interval requires a plain 16-packet burst')
    if udp_audit_staging not in ('0', '1') or (udp_audit_staging == '1' and (udp_burst != '1' or udp_burst_count != 16 or udp_tail_short != '0' or udp_reverse != '0' or udp_interval_ms != 250)):
        raise ValueError('Staging audit requires a plain 16-packet burst')
    udp_settle_ms = int(os.environ.get('NIHOS_C6_UDP_SETTLE_MS', '2000'))
    if udp_settle_ms not in (2000, 8000) or (udp_settle_ms != 2000 and udp_burst != '1'):
        raise ValueError('UDP settle must be 2000 or 8000 milliseconds in burst mode')
    if udp_burst not in ('0', '1') or (udp_burst == '1' and long_dma != '1'):
        raise ValueError('UDP burst requires long DMA profile')
    if long_dma not in ('0', '1') or (long_dma == '1' and protocol != 'hosted'):
        raise ValueError('Long DMA requires Hosted diagnostic mode')
    peer_ip = os.environ.get('NIHOS_C6_UDP_PEER_IP', '')
    peer_mac = os.environ.get('NIHOS_C6_UDP_PEER_MAC', '')
    udp_enabled = bool(peer_ip or peer_mac)
    udp_ip, udp_mac, udp_port = 0, bytes(6), 44444
    if udp_enabled:
        if long_dma != '1' or not peer_ip or not peer_mac:
            raise ValueError('Explicit IP and MAC require long DMA profile')
        address = ipaddress.IPv4Address(peer_ip)
        udp_mac = bytes.fromhex(peer_mac.replace(':', ''))
        udp_port = int(os.environ.get('NIHOS_C6_UDP_PEER_PORT', '44444'))
        if (address.is_multicast or address.is_unspecified or address.is_loopback or
                int(address) == 0xffffffff or len(udp_mac) != 6 or udp_mac[0] & 1 or
                udp_mac == bytes(6) or not 1 <= udp_port <= 65535):
            raise ValueError('Invalid diagnostic peer')
        udp_ip = int(address)
    if udp_burst == '1' and not udp_enabled:
        raise ValueError('UDP burst requires explicit peer')
    if ipv6 not in ('0', '1') or (ipv6 == '1' and protocol != 'hosted'):
        raise ValueError('IPv6 requires Hosted mode')
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
            f'pub const ipv6 = {str(ipv6 == "1").lower()};\n'
            f'pub const long_dma = {str(long_dma == "1").lower()};\n'
            f'pub const udp_enabled = {str(udp_enabled).lower()};\n'
            f'pub const udp_burst = {str(udp_burst == "1").lower()};\n'
            f'pub const udp_burst_count: u32 = {udp_burst_count};\n'
            f'pub const udp_tail_short = {str(udp_tail_short == "1").lower()};\n'
            f'pub const udp_pause_after_16 = {str(udp_pause_after_16 == "1").lower()};\n'
            f'pub const udp_reverse = {str(udp_reverse == "1").lower()};\n'
            f'pub const udp_interval_ms: u32 = {udp_interval_ms};\n'
            f'pub const udp_audit_staging = {str(udp_audit_staging == "1").lower()};\n'
            f'pub const udp_settle_ms: u32 = {udp_settle_ms};\n'
            f'pub const udp_ip: u32 = {udp_ip};\n'
            f'pub const udp_mac = {array(udp_mac)};\n'
            f'pub const udp_port: u16 = {udp_port};\n'
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
