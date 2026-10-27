# Synthetic DHCP wire fixtures

Generated locally using Scapy 2.6.1, independently of the Zig encoder. These
are synthetic Ethernet/IPv4/UDP/BOOTP/DHCP OFFER and ACK packets, not a capture
from a device or evidence of AP connectivity. No user credentials are present.
Both have valid, nonzero UDP checksums and IPv4 checksums.

Inputs: server MAC `02:aa:bb:cc:dd:ee`, client MAC `02:03:04:05:06:07`,
server `192.0.2.1`, destination `255.255.255.255`, IPv4 ID `0x1234`,
UDP ports 67→68, BOOTP op=2/htype=1/hlen=6/xid=`0x12345678`,
yiaddr=`192.0.2.12`, chaddr=client MAC. DHCP options in order:
message-type (`offer` or `ack`), server_id=`192.0.2.1`,
subnet_mask=`255.255.255.0`, router=`192.0.2.1`, lease_time=3600, end.
Other fields use Scapy defaults. Files contain `raw(Ether()/IP()/UDP()/BOOTP()/DHCP())`.
Tests verify acquisition and reject a corrupted checksummed ACK.
