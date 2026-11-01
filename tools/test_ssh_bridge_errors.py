#!/usr/bin/env python3
"""Ensure bridge backpressure cannot hide a fatal socket error."""
import unittest
from ssh_openssh_probe import BridgeSocket


class FakeBridge:
    def __init__(self, result):
        self.result = result

    def bridge_poll(self):
        return True

    def bridge_read(self, _buffer, _size):
        return self.result

    def bridge_write(self, _buffer, _size):
        return self.result


class BridgeErrors(unittest.TestCase):
    def socket(self, result):
        sock = BridgeSocket.__new__(BridgeSocket)
        sock.bridge = FakeBridge(result)
        sock.timeout = 1
        sock.blocking = False
        return sock

    def test_backpressure_is_retryable(self):
        with self.assertRaises(BlockingIOError):
            self.socket(-1).recv(1)
        with self.assertRaises(BlockingIOError):
            self.socket(-1).send(b'x')

    def test_failure_is_not_backpressure(self):
        for operation in (lambda sock: sock.recv(1), lambda sock: sock.send(b'x')):
            with self.assertRaises(OSError) as failure:
                operation(self.socket(-2))
            self.assertNotIsInstance(failure.exception, BlockingIOError)


if __name__ == '__main__':
    unittest.main()
