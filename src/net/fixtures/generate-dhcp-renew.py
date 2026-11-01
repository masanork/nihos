#!/usr/bin/env python3
"""Derive a synthetic renewal ACK from the independently generated ACK."""
from pathlib import Path
import struct
import sys

root = Path(__file__).resolve().parent
packet = bytearray((root / 'dhcp-ack.bin').read_bytes())
ip = 14
udp = ip + (packet[ip] & 15) * 4
length = struct.unpack_from('!H', packet, udp + 4)[0]
assert udp + length <= len(packet) and packet[ip + 9] == 17
assert struct.unpack_from('!I', packet, udp + 8 + 4)[0] == 0x12345678
struct.pack_into('!I', packet, udp + 8 + 4, (0x12345678 + 0x9e3779b9) & 0xffffffff)
struct.pack_into('!H', packet, udp + 6, 0)
pseudo = packet[ip + 12:ip + 20] + bytes([0, 17]) + struct.pack('!H', length)
data = pseudo + packet[udp:udp + length]
if len(data) % 2:
    data += b'\0'
sum16 = sum(struct.unpack(f'!{len(data) // 2}H', data))
while sum16 >> 16:
    sum16 = (sum16 & 0xffff) + (sum16 >> 16)
checksum = (~sum16 & 0xffff) or 0xffff
struct.pack_into('!H', packet, udp + 6, checksum)
output = Path(sys.argv[1]) if len(sys.argv) == 2 else root / 'dhcp-renew-ack.bin'
output.write_bytes(packet)
