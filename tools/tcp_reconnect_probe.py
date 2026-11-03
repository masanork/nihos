#!/usr/bin/env python3
"""Exercise two TCP connections on one synthetic station lease via libslirp."""
import ctypes as c
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
ZIG = os.environ.get("ZIG", str(ROOT / ".tools/zig-0.17.0/zig"))
PREFIX = Path(os.environ["SLIRP_PREFIX"])
LIBDIR = Path(os.environ.get("SLIRP_LIBDIR") or PREFIX / "lib")


def wait(bridge, predicate):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if not bridge.bridge_poll():
            raise RuntimeError("TCP bridge failed")
        if predicate():
            return
        time.sleep(0.001)
    raise TimeoutError("TCP reconnect probe timed out")


def run():
    with tempfile.TemporaryDirectory(prefix="nihos-tcp-reconnect-") as temporary:
        directory = Path(temporary)
        suffix = "dylib" if sys.platform == "darwin" else "so"
        tcp_path = directory / ("libtcp." + suffix)
        bridge_path = directory / ("libbridge." + suffix)
        subprocess.run([ZIG, "build-lib", "-dynamic", "-O", "ReleaseSafe", "-femit-bin=" + str(tcp_path), "src/net/tcp_host_probe.zig"], cwd=ROOT, check=True)
        subprocess.run([os.environ.get("CC", "cc"), "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations", "-I" + str(PREFIX / "include"), "tools/tcp_slirp_bridge.c", "-L" + str(LIBDIR), "-lslirp", str(tcp_path), "-Wl,-rpath," + str(LIBDIR), "-Wl,-rpath," + str(directory), "-o", str(bridge_path)], cwd=ROOT, check=True)
        tcp = c.CDLL(str(tcp_path))
        bridge = c.CDLL(str(bridge_path))
        tcp.tcp_link_reopen.argtypes = [c.c_uint16, c.c_uint16]
        tcp.tcp_link_reopen.restype = c.c_bool
        tcp.tcp_link_cancel.restype = c.c_bool
        bridge.bridge_open.argtypes = [c.c_uint16]
        bridge.bridge_open.restype = c.c_bool
        bridge.bridge_poll.restype = c.c_bool
        bridge.bridge_ready.restype = c.c_bool
        bridge.bridge_closed.restype = c.c_bool
        bridge.bridge_close_write.restype = c.c_bool
        bridge.bridge_write.argtypes = [c.c_void_p, c.c_size_t]
        bridge.bridge_write.restype = c.c_ssize_t
        bridge.bridge_read.argtypes = [c.c_void_p, c.c_size_t]
        bridge.bridge_read.restype = c.c_ssize_t
        errors = []
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen(2)
            server.settimeout(20)
            port = server.getsockname()[1]

            def serve():
                try:
                    for expected in (b"first", b"second"):
                        with server.accept()[0] as connection:
                            connection.settimeout(15)
                            data = b""
                            while len(data) < len(expected):
                                part = connection.recv(len(expected) - len(data))
                                if not part:
                                    raise RuntimeError("early EOF")
                                data += part
                            if data != expected:
                                raise RuntimeError("wrong request")
                            connection.sendall(data.upper())
                except Exception as error:
                    errors.append(error)

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            if not bridge.bridge_open(port):
                raise RuntimeError("initial open failed")
            try:
                for index, message in enumerate((b"first", b"second")):
                    if index:
                        if tcp.tcp_link_reopen(port, 50001):
                            raise RuntimeError("reused local port accepted")
                        if not tcp.tcp_link_reopen(port, 50002):
                            raise RuntimeError("fresh local port rejected")
                    wait(bridge, bridge.bridge_ready)
                    buf = c.create_string_buffer(message)
                    sent = 0
                    write_deadline = time.monotonic() + 15
                    while sent < len(message):
                        if time.monotonic() >= write_deadline:
                            raise TimeoutError("TCP write timed out")
                        n = bridge.bridge_write(c.byref(buf, sent), len(message) - sent)
                        if n < -1:
                            raise RuntimeError("write failed")
                        if n > 0:
                            sent += n
                        wait(bridge, lambda: True)
                    response = bytearray()
                    def read_response():
                        out = c.create_string_buffer(32)
                        n = bridge.bridge_read(out, len(out))
                        if n == -2:
                            raise RuntimeError("read failed")
                        if n == 0:
                            raise RuntimeError("EOF before response")
                        if n > 0:
                            response.extend(out.raw[:n])
                        return len(response) == len(message)
                    wait(bridge, read_response)
                    if response != message.upper():
                        raise RuntimeError("incorrect response")
                    if not bridge.bridge_close_write():
                        raise RuntimeError("close failed")
                    wait(bridge, bridge.bridge_closed)
                    if not tcp.tcp_link_cancel():
                        raise RuntimeError("retiring connection failed")
            finally:
                bridge.bridge_destroy()
            worker.join(20)
            if worker.is_alive() or errors:
                raise RuntimeError(f"server failed: {errors}")
    print("Two TCP sessions on one lease, unique local ports, data and FIN: OK")


if __name__ == "__main__":
    run()
