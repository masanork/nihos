#!/usr/bin/env python3
"""Local OpenSSH KEX, temporary public-key login, and PTY command probe."""
import base64
import ctypes as c
import hashlib
import getpass
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
        p.probe_init.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p, c.c_size_t]; p.probe_init.restype = c.c_size_t
        p.probe_server_init.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t]; p.probe_server_init.restype = c.c_size_t
        p.probe_reply.argtypes = [c.c_void_p, c.c_size_t]; p.probe_reply.restype = c.c_bool
        p.probe_newkeys.argtypes = [c.c_void_p, c.c_size_t]; p.probe_newkeys.restype = c.c_size_t
        p.probe_activate.argtypes = [c.c_void_p, c.c_size_t, c.c_uint32]; p.probe_activate.restype = c.c_bool
        p.probe_pack.argtypes = [c.c_void_p, c.c_size_t, c.c_uint32, c.c_void_p, c.c_void_p, c.c_size_t]; p.probe_pack.restype = c.c_size_t
        p.probe_feed.argtypes = [c.c_void_p, c.c_size_t]; p.probe_feed.restype = c.c_ssize_t
        p.probe_payload.argtypes = [c.c_void_p, c.c_size_t]; p.probe_payload.restype = c.c_size_t
        p.probe_auth_public.argtypes = [c.c_void_p, c.c_void_p]; p.probe_auth_public.restype = c.c_bool
        p.probe_auth.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p, c.c_size_t]; p.probe_auth.restype = c.c_size_t
        p.probe_service.argtypes = [c.c_void_p, c.c_size_t]; p.probe_service.restype = c.c_size_t
        p.probe_release.argtypes = []
        p.probe_channel_action.argtypes = [c.c_uint8, c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t]; p.probe_channel_action.restype = c.c_size_t
        p.probe_channel_receive.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t]; p.probe_channel_receive.restype = c.c_ssize_t
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
                secret = buffer(os.urandom(32))
                size = p.probe_init(out, len(out), buffer(os.urandom(16)), secret, buffer(pin), buffer(server_banner), len(server_banner))
                assert size
                client_init = out.raw[:size]
                sock.sendall(clear_packet(client_init))
                server_init = read_packet(sock)
                assert server_init[0] == 20
                ecdh = c.create_string_buffer(64)
                size = p.probe_server_init(buffer(server_init), len(server_init), ecdh, len(ecdh))
                assert size
                sock.sendall(clear_packet(ecdh.raw[:size]))
                reply = read_packet(sock)
                assert p.probe_reply(buffer(reply), len(reply)), "server proof rejected or wrong pin accepted"
                newkeys = read_packet(sock)
                key_message = c.create_string_buffer(8)
                size = p.probe_newkeys(key_message, len(key_message))
                assert size
                sock.sendall(clear_packet(key_message.raw[:size]))
                assert p.probe_activate(buffer(newkeys), len(newkeys), 3)
                request_buffer = c.create_string_buffer(64)
                request_len = p.probe_service(request_buffer, len(request_buffer))
                assert request_len
                request = request_buffer.raw[:request_len]
                packed = c.create_string_buffer(256)
                size = p.probe_pack(buffer(request), len(request), 3, buffer(os.urandom(32)), packed, len(packed))
                assert size
                sock.sendall(packed.raw[:size])
                plaintext = c.create_string_buffer(1024)
                while not p.probe_payload(plaintext, len(plaintext)):
                    b = exact(sock, 1)
                    assert p.probe_feed(buffer(b), 1) == 1, "encrypted server packet rejected"
                length = p.probe_payload(plaintext, len(plaintext))
                assert p.probe_channel_receive(plaintext, length, c.create_string_buffer(1), 1) == 7
                p.probe_release()
                seq = 4
                def send(payload):
                    nonlocal seq
                    data = c.create_string_buffer(len(payload) + 128)
                    n = p.probe_pack(buffer(payload), len(payload), seq, buffer(os.urandom(32)), data, len(data))
                    assert n
                    seq += 1
                    sock.sendall(data.raw[:n])
                def receive():
                    while True:
                        data = c.create_string_buffer(35000)
                        while not p.probe_payload(data, len(data)):
                            b = exact(sock, 1)
                            if p.probe_feed(buffer(b), 1) != 1:
                                raise RuntimeError("encrypted server packet rejected")
                        size = p.probe_payload(data, len(data))
                        result = data.raw[:size]
                        p.probe_release()
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
                print("OpenSSH KEX, host pin, public-key authentication and interactive PTY: OK")
        finally:
            server.terminate()
            try: server.wait(timeout=3)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
            log.close()


if __name__ == "__main__":
    run()
