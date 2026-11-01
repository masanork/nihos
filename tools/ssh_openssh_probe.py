#!/usr/bin/env python3
"""Local OpenSSH first KEX and encrypted service request; no login or device."""
import base64
import ctypes as c
import hashlib
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ZIG = os.environ.get("ZIG", str(ROOT / ".tools/zig-0.17.0/zig"))


def string(value):
    return struct.pack(">I", len(value)) + value


def clear_packet(payload):
    padding = 8 - ((5 + len(payload)) % 8)
    if padding < 4:
        padding += 8
    return struct.pack(">IB", len(payload) + padding + 1, padding) + payload + os.urandom(padding)


def exact(sock, size):
    data = b""
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise RuntimeError("server closed connection")
        data += part
    return data


def read_packet(sock):
    length = struct.unpack(">I", exact(sock, 4))[0]
    if length < 12 or length > 35000:
        raise RuntimeError("invalid packet length")
    data = exact(sock, length)
    return data[1:len(data) - data[0]]


def buffer(data):
    return c.create_string_buffer(data, len(data))


def run():
    with tempfile.TemporaryDirectory(prefix="nihos-ssh-test-") as tmp:
        tmp = Path(tmp)
        lib = tmp / ("probe.dylib" if sys.platform == "darwin" else "probe.so")
        subprocess.run([ZIG, "build-lib", "-dynamic", "-O", "ReleaseSafe", "-femit-bin=" + str(lib), "src/net/ssh_kex_host_probe.zig"], cwd=ROOT, check=True)
        p = c.CDLL(str(lib))
        p.probe_init.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p]; p.probe_init.restype = c.c_size_t
        p.probe_public.argtypes = [c.c_void_p, c.c_void_p]
        p.probe_finish.argtypes = [c.c_void_p, c.c_size_t] * 4 + [c.c_void_p, c.c_void_p, c.c_void_p, c.c_size_t, c.c_uint32]; p.probe_finish.restype = c.c_bool
        p.probe_pack.argtypes = [c.c_void_p, c.c_size_t, c.c_uint32, c.c_void_p, c.c_void_p, c.c_size_t]; p.probe_pack.restype = c.c_size_t
        p.probe_feed.argtypes = [c.c_void_p, c.c_size_t]; p.probe_feed.restype = c.c_ssize_t
        p.probe_payload.argtypes = [c.c_void_p, c.c_size_t]; p.probe_payload.restype = c.c_size_t
        key = tmp / "host"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        pin = hashlib.sha256(base64.b64decode(key.with_suffix(".pub").read_text().split()[1])).digest()
        with socket.socket() as picker:
            picker.bind(("127.0.0.1", 0)); port = picker.getsockname()[1]
        config = tmp / "sshd_config"
        config.write_text(f"Port {port}\nListenAddress 127.0.0.1\nHostKey {key}\nPidFile {tmp}/pid\nPasswordAuthentication no\nUsePAM no\n")
        log = (tmp / "sshd.log").open("wb")
        server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    sock = socket.create_connection(("127.0.0.1", port), timeout=1); break
                except OSError:
                    if time.monotonic() >= deadline or server.poll() is not None:
                        log.flush(); raise RuntimeError((tmp / "sshd.log").read_text())
                    time.sleep(0.05)
            with sock:
                sock.settimeout(5)
                client_banner = b"SSH-2.0-nihos_1.0"
                sock.sendall(client_banner + b"\r\n")
                banner = b""
                while not banner.endswith(b"\n"):
                    banner += exact(sock, 1)
                server_banner = banner.rstrip(b"\r\n")
                out = c.create_string_buffer(512)
                size = p.probe_init(out, len(out), buffer(os.urandom(16)))
                assert size
                client_init = out.raw[:size]
                sock.sendall(clear_packet(client_init))
                server_init = read_packet(sock)
                assert server_init[0] == 20
                secret = buffer(os.urandom(32)); public = c.create_string_buffer(32)
                p.probe_public(secret, public)
                sock.sendall(clear_packet(b"\x1e" + string(public.raw)))
                reply = read_packet(sock)
                assert reply[0] == 31
                newkeys = read_packet(sock)
                assert newkeys == b"\x15"
                args = [buffer(v) for v in (client_banner, server_banner, client_init, server_init)]
                def finish(candidate_pin):
                    return p.probe_finish(args[0], len(client_banner), args[1], len(server_banner), args[2], len(client_init), args[3], len(server_init), secret, buffer(candidate_pin), buffer(reply), len(reply), 3)
                assert not finish(bytes(32)), "wrong host pin accepted"
                assert finish(pin), "valid server proof rejected"
                sock.sendall(clear_packet(b"\x15"))
                request = b"\x05" + string(b"ssh-userauth")
                packed = c.create_string_buffer(256)
                size = p.probe_pack(buffer(request), len(request), 3, buffer(os.urandom(32)), packed, len(packed))
                assert size
                sock.sendall(packed.raw[:size])
                plaintext = c.create_string_buffer(1024)
                while not p.probe_payload(plaintext, len(plaintext)):
                    b = exact(sock, 1)
                    assert p.probe_feed(buffer(b), 1) == 1, "encrypted server packet rejected"
                length = p.probe_payload(plaintext, len(plaintext))
                assert plaintext.raw[:length] == b"\x06" + string(b"ssh-userauth")
                print("OpenSSH KEX, pinned host proof, NEWKEYS and encrypted service accept: OK")
        finally:
            server.terminate()
            try: server.wait(timeout=3)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
            log.close()


if __name__ == "__main__":
    run()
