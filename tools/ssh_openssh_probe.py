#!/usr/bin/env python3
"""Local OpenSSH KEX, temporary public-key login, and PTY command probe."""
import base64
import ctypes as c
import hashlib
import getpass
import os
import select
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


def exact(sock, size):
    data = b""
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise RuntimeError("server closed connection")
        data += part
    return data


def buffer(data):
    return c.create_string_buffer(data, len(data))


class BridgeSocket:
    """Socket-shaped host fixture backed by nihos TCP and libslirp."""
    def __init__(self, bridge, port):
        self.bridge = bridge
        self.blocking = True
        self.timeout = 20
        if not bridge.bridge_open(port): raise RuntimeError("TCP bridge initialization failed")
        self.wait(lambda: bridge.bridge_ready())
    def wait(self, condition):
        until = time.monotonic() + self.timeout
        while not condition():
            if not self.bridge.bridge_poll(): raise RuntimeError("TCP bridge failed")
            if time.monotonic() >= until: raise TimeoutError("TCP bridge timeout")
            time.sleep(0.001)
    def settimeout(self, value): self.timeout = value
    def setblocking(self, value): self.blocking = value
    def recv(self, size):
        result = c.create_string_buffer(size)
        until = time.monotonic() + self.timeout
        while True:
            if not self.bridge.bridge_poll(): raise OSError("TCP bridge failed")
            n = self.bridge.bridge_read(result, size)
            if n >= 0: return result.raw[:n]
            if not self.blocking: raise BlockingIOError()
            if time.monotonic() >= until: raise TimeoutError("TCP receive timeout")
            time.sleep(0.001)
    def send(self, data):
        if not self.bridge.bridge_poll(): raise OSError("TCP bridge failed")
        n = self.bridge.bridge_write(buffer(data), len(data))
        if n < 0: raise BlockingIOError()
        return n
    def sendall(self, data):
        at = 0
        until = time.monotonic() + self.timeout
        while at < len(data):
            try: at += self.send(data[at:])
            except BlockingIOError:
                if time.monotonic() >= until: raise TimeoutError("TCP send timeout")
                time.sleep(0.001)
    def __enter__(self): return self
    def __exit__(self, exc_type, unused_value, unused_traceback):
        try:
            if exc_type is None:
                if not self.bridge.bridge_close_write(): raise RuntimeError("TCP close failed")
                self.wait(lambda: self.bridge.bridge_closed())
        finally:
            self.bridge.bridge_destroy()


def run():
    with tempfile.TemporaryDirectory(prefix="nihos-ssh-test-") as tmp:
        tmp = Path(tmp)
        lib = tmp / ("probe.dylib" if sys.platform == "darwin" else "probe.so")
        subprocess.run([ZIG, "build-lib", "-dynamic", "-O", "ReleaseSafe", "-femit-bin=" + str(lib), "src/net/ssh_kex_host_probe.zig"], cwd=ROOT, check=True)
        p = c.CDLL(str(lib))
        p.probe_init.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p, c.c_size_t]; p.probe_init.restype = c.c_size_t
        p.probe_server_init.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t]; p.probe_server_init.restype = c.c_size_t
        p.probe_reply.argtypes = [c.c_void_p, c.c_size_t]; p.probe_reply.restype = c.c_bool
        p.probe_newkeys.argtypes = [c.c_void_p, c.c_size_t]; p.probe_newkeys.restype = c.c_size_t
        p.probe_activate.argtypes = [c.c_void_p, c.c_size_t]; p.probe_activate.restype = c.c_bool
        callback = c.CFUNCTYPE(c.c_ssize_t, c.c_void_p, c.c_size_t)
        p.probe_socket.argtypes = [callback, callback]
        p.probe_poll.restype = c.c_bool
        p.probe_pending.restype = c.c_size_t
        p.probe_pause.argtypes = [c.c_bool]
        p.probe_pack.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p]; p.probe_pack.restype = c.c_bool
        p.probe_payload.argtypes = [c.c_void_p, c.c_size_t]; p.probe_payload.restype = c.c_size_t
        p.probe_auth_public.argtypes = [c.c_void_p, c.c_void_p]; p.probe_auth_public.restype = c.c_bool
        p.probe_auth.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p, c.c_size_t]; p.probe_auth.restype = c.c_size_t
        p.probe_service.argtypes = [c.c_void_p, c.c_size_t]; p.probe_service.restype = c.c_size_t
        p.probe_release.argtypes = []
        p.probe_channel_action.argtypes = [c.c_uint8, c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t]; p.probe_channel_action.restype = c.c_size_t
        p.probe_channel_receive.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t]; p.probe_channel_receive.restype = c.c_ssize_t
        bridge = None
        if os.environ.get("NIHOS_SSH_SLIRP") == "1":
            prefix = Path(os.environ["SLIRP_PREFIX"])
            ext = "dylib" if sys.platform == "darwin" else "so"
            tcp_lib = tmp / ("libtcp_probe." + ext)
            bridge_lib = tmp / ("libbridge." + ext)
            subprocess.run([ZIG, "build-lib", "-dynamic", "-O", "ReleaseSafe", "-femit-bin=" + str(tcp_lib), "src/net/tcp_host_probe.zig"], cwd=ROOT, check=True)
            subprocess.run([os.environ.get("CC", "cc"), "-shared", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations", "-I" + str(prefix / "include"), "tools/tcp_slirp_bridge.c", str(prefix / "lib" / ("libslirp." + ext)), str(tcp_lib), "-Wl,-rpath," + str(prefix / "lib"), "-Wl,-rpath," + str(tmp), "-o", str(bridge_lib)], cwd=ROOT, check=True)
            bridge = c.CDLL(str(bridge_lib))
            bridge.bridge_open.argtypes = [c.c_uint16]; bridge.bridge_open.restype = c.c_bool
            bridge.bridge_poll.restype = c.c_bool
            bridge.bridge_ready.restype = c.c_bool
            bridge.bridge_read.argtypes = [c.c_void_p, c.c_size_t]; bridge.bridge_read.restype = c.c_ssize_t
            bridge.bridge_write.argtypes = [c.c_void_p, c.c_size_t]; bridge.bridge_write.restype = c.c_ssize_t
            bridge.bridge_close_write.restype = c.c_bool
            bridge.bridge_closed.restype = c.c_bool
        key = tmp / "host"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        pin = hashlib.sha256(base64.b64decode(key.with_suffix(".pub").read_text().split()[1])).digest()
        with socket.socket() as picker:
            picker.bind(("127.0.0.1", 0)); port = picker.getsockname()[1]
        seed = buffer(os.urandom(32)); user_public = c.create_string_buffer(32)
        assert p.probe_auth_public(seed, user_public)
        authorized = tmp / "authorized_keys"
        authorized.write_bytes(b"ssh-ed25519 " + base64.b64encode(string(b"ssh-ed25519") + string(user_public.raw)) + b"\n")
        tmp.chmod(0o755); authorized.chmod(0o644)
        config = tmp / "sshd_config"
        config.write_text(f"Port {port}\nListenAddress 127.0.0.1\nHostKey {key}\nPidFile {tmp}/pid\nAuthorizedKeysFile {authorized}\nStrictModes no\nPasswordAuthentication no\nUsePAM no\n")
        log = (tmp / "sshd.log").open("wb")
        server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    sock = socket.create_connection(("127.0.0.1", port), timeout=1)
                    if bridge:
                        sock.close(); sock = BridgeSocket(bridge, port)
                    break
                except OSError:
                    if time.monotonic() >= deadline or server.poll() is not None:
                        log.flush(); raise RuntimeError((tmp / "sshd.log").read_text())
                    time.sleep(0.05)
            with sock:
                sock.settimeout(20 if bridge else 5)
                client_banner = b"SSH-2.0-nihos_1.0"
                sock.sendall(client_banner + b"\r\n")
                banner = b""
                while not banner.endswith(b"\n"):
                    banner += exact(sock, 1)
                server_banner = banner.rstrip(b"\r\n")
                sock.setblocking(False)
                @callback
                def socket_read(dst, cap):
                    try:
                        data = sock.recv(min(cap, 31))
                        c.memmove(dst, data, len(data))
                        return len(data)
                    except BlockingIOError:
                        return -1
                    except OSError:
                        return -2
                @callback
                def socket_write(src, length):
                    try:
                        return sock.send(c.string_at(src, min(length, 512 if bridge else 3)))
                    except BlockingIOError:
                        return -1
                    except OSError:
                        return -2
                p.probe_socket(socket_read, socket_write)
                def poll_until(predicate):
                    deadline = time.monotonic() + (20 if bridge else 5)
                    while not predicate():
                        assert p.probe_poll(), "socket pump failed"
                        if time.monotonic() > deadline: raise TimeoutError("socket pump timeout")
                        if bridge: time.sleep(0.001)
                        else: select.select([sock], [sock] if p.probe_pending() else [], [], 0.001)
                def send(payload):
                    assert p.probe_pack(buffer(payload), len(payload), buffer(os.urandom(32)))
                    poll_until(lambda: p.probe_pending() == 0)
                def raw_receive(pause=False):
                    data = c.create_string_buffer(35000)
                    poll_until(lambda: p.probe_payload(data, len(data)) != 0)
                    size = p.probe_payload(data, len(data))
                    result = data.raw[:size]
                    if pause: p.probe_pause(True)
                    p.probe_release()
                    return result
                out = c.create_string_buffer(512)
                secret = buffer(os.urandom(32))
                size = p.probe_init(out, len(out), buffer(os.urandom(16)), secret, buffer(pin), buffer(server_banner), len(server_banner))
                assert size
                client_init = out.raw[:size]
                send(client_init)
                server_init = raw_receive()
                assert server_init[0] == 20
                ecdh = c.create_string_buffer(64)
                size = p.probe_server_init(buffer(server_init), len(server_init), ecdh, len(ecdh))
                assert size
                send(ecdh.raw[:size])
                reply = raw_receive()
                assert p.probe_reply(buffer(reply), len(reply)), "server proof rejected or wrong pin accepted"
                newkeys = raw_receive(pause=True)
                key_message = c.create_string_buffer(8)
                size = p.probe_newkeys(key_message, len(key_message))
                assert size
                send(key_message.raw[:size])
                assert p.probe_activate(buffer(newkeys), len(newkeys))
                p.probe_pause(False)
                request_buffer = c.create_string_buffer(64)
                request_len = p.probe_service(request_buffer, len(request_buffer))
                assert request_len
                request = request_buffer.raw[:request_len]
                send(request)
                accepted = raw_receive()
                assert p.probe_channel_receive(buffer(accepted), len(accepted), c.create_string_buffer(1), 1) == 7
                def receive():
                    while True:
                        result = raw_receive()
                        if result[0] in (2, 4): continue
                        if result[0] == 80:
                            name_len = struct.unpack(">I", result[1:5])[0]
                            if result[5 + name_len] != 0: send(b"\x52")
                            continue
                        return result
                username = getpass.getuser().encode()
                auth = c.create_string_buffer(512)
                n = p.probe_auth(buffer(username), len(username), seed, auth, len(auth))
                assert n
                send(auth.raw[:n])
                result = receive()
                event = p.probe_channel_receive(buffer(result), len(result), c.create_string_buffer(1), 1)
                while event == 9:
                    result = receive()
                    event = p.probe_channel_receive(buffer(result), len(result), c.create_string_buffer(1), 1)
                if event != 8:
                    log.flush(); raise RuntimeError(f"authentication failed: {result.hex()}\n{(tmp / 'sshd.log').read_text()}")
                def action(code, data=b""):
                    out = c.create_string_buffer(1024)
                    n = p.probe_channel_action(code, buffer(data), len(data), out, len(out))
                    assert n, f"channel action {code} failed"
                    send(out.raw[:n])
                def channel_event():
                    packet = receive()
                    out = c.create_string_buffer(32768)
                    event = p.probe_channel_receive(buffer(packet), len(packet), out, len(out))
                    assert event >= 0, f"channel rejected {packet.hex()}"
                    return event, out.raw[:max(0, event - 100)]
                def wait_event(expected):
                    for _ in range(12):
                        event, _ = channel_event()
                        if event == expected: return
                        assert event == 4, event
                    raise RuntimeError(f"channel event {expected} not received")
                action(0); wait_event(1)
                action(1); wait_event(2)
                action(2); wait_event(3)
                action(3, b"printf ni%s_ssh_ok hos\n")
                output = b""
                for _ in range(256):
                    event, data = channel_event()
                    if event >= 100: output += data
                    if b"nihos_ssh_ok" in output: break
                assert b"nihos_ssh_ok" in output, output
                action(3, b"exit\n")
                for _ in range(24):
                    event, _ = channel_event()
                    if event == 6:
                        action(5)
                        break
                else:
                    raise RuntimeError("channel close not received")
            print("OpenSSH KEX, host pin, public-key authentication and interactive PTY: OK" + (" (nihos TCP via libslirp, TCP FIN confirmed)" if bridge else ""))
        finally:
            server.terminate()
            try: server.wait(timeout=3)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
            log.close()


if __name__ == "__main__":
    run()
