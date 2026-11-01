#!/usr/bin/env python3
"""Loopback check for the independent diagnostic UDP receiver."""
import socket
import unittest

from hosted_udp_capture import PeerCapture


class PeerCaptureTest(unittest.TestCase):
    def test_burst_is_received_and_echoed_while_caller_is_idle(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as peer, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            peer.bind(('127.0.0.1', 0))
            client.settimeout(2)
            capture = PeerCapture(peer)
            capture.start()
            try:
                for attempt in range(1, 19):
                    payload = bytearray(i % 256 for i in range(1200))
                    payload[:8] = b'NIHOSUDP'
                    payload[8] = attempt
                    client.sendto(payload, peer.getsockname())
                echoed = [client.recvfrom(2048)[0][8] for _ in range(18)]
                marker = b'NIHOSUDP' + bytes(range(8, 65))
                client.sendto(marker, peer.getsockname())
                self.assertEqual(client.recvfrom(2048)[0], marker)
            finally:
                rows = capture.close()
            received = [row for row in rows if row['event'] == 'received']
            self.assertEqual(echoed, list(range(1, 19)))
            self.assertEqual([row['attempt'] for row in received], list(range(1, 19)) + [None])
            self.assertTrue(all(row['payload_matches'] for row in received))
            self.assertEqual(len([row for row in rows if row['event'] == 'echoed']), 19)
            stamps = [row['elapsed_us'] for row in received]
            self.assertEqual(stamps, sorted(stamps))


if __name__ == '__main__':
    unittest.main()
