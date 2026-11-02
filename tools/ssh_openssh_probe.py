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
        self.closed_by_controller = False
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
            if n != -1: raise OSError("TCP bridge read failed")
            if not self.blocking: raise BlockingIOError()
            if time.monotonic() >= until: raise TimeoutError("TCP receive timeout")
            time.sleep(0.001)
    def send(self, data):
        if not self.bridge.bridge_poll(): raise OSError("TCP bridge failed")
        n = self.bridge.bridge_write(buffer(data), len(data))
        if n == -1: raise BlockingIOError()
        if n < 0: raise OSError("TCP bridge write failed")
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
            if exc_type is None and not self.closed_by_controller:
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
        p.probe_driver_begin.argtypes = [c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p, c.c_size_t]; p.probe_driver_begin.restype = c.c_bool
        p.probe_driver_step.argtypes = [c.c_void_p]; p.probe_driver_step.restype = c.c_ssize_t
        p.probe_terminal_poll.argtypes = [c.c_uint64, c.c_void_p]; p.probe_terminal_poll.restype = c.c_ssize_t
        p.probe_terminal_read.argtypes = [c.c_uint64, c.c_void_p, c.c_void_p, c.c_size_t]; p.probe_terminal_read.restype = c.c_ssize_t
        p.probe_terminal_write.argtypes = [c.c_uint64, c.c_void_p, c.c_void_p, c.c_size_t]; p.probe_terminal_write.restype = c.c_ssize_t
        p.probe_client_begin.argtypes = [c.c_void_p, c.c_void_p, c.c_void_p, c.c_uint64, c.c_uint64]
        p.probe_client_poll.argtypes = [c.c_uint64, c.c_void_p, c.c_void_p, c.c_size_t, c.c_void_p]; p.probe_client_poll.restype = c.c_ssize_t
        p.probe_connection_begin.argtypes = [c.c_void_p, c.c_void_p, c.c_void_p, c.c_uint64, c.c_uint64]
        p.probe_connection_poll.argtypes = [c.c_uint64, c.c_void_p]; p.probe_connection_poll.restype = c.c_ssize_t
        p.probe_ident_poll.restype = c.c_ssize_t
        p.probe_ident_banner.argtypes = [c.c_void_p, c.c_size_t]; p.probe_ident_banner.restype = c.c_size_t
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
            libdir = Path(os.environ.get("SLIRP_LIBDIR") or prefix / "lib")
            ext = "dylib" if sys.platform == "darwin" else "so"
            tcp_lib = tmp / ("libtcp_host_probe." + ext)
            bridge_lib = tmp / ("libbridge." + ext)
            subprocess.run([ZIG, "build-lib", "-dynamic", "-O", "ReleaseSafe", "-femit-bin=" + str(tcp_lib), "src/net/tcp_host_probe.zig"], cwd=ROOT, check=True)
            subprocess.run([os.environ.get("CC", "cc"), "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations", "-I" + str(prefix / "include"), "tools/tcp_slirp_bridge.c", "-L" + str(libdir), "-lslirp", str(tcp_lib), "-Wl,-rpath," + str(libdir), "-Wl,-rpath," + str(tmp), "-o", str(bridge_lib)], cwd=ROOT, check=True)
            tcp_ffi = c.CDLL(str(tcp_lib))
            tcp_ffi.hosted_ssh_abort.argtypes = []
            tcp_ffi.tcp_link_cancel.restype = c.c_bool
            tcp_ffi.hosted_ssh_begin.argtypes = [c.c_void_p, c.c_void_p, c.c_void_p]; tcp_ffi.hosted_ssh_begin.restype = c.c_bool
            tcp_ffi.hosted_ssh_poll.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_void_p]; tcp_ffi.hosted_ssh_poll.restype = c.c_ssize_t
            tcp_ffi.hosted_ssh_read.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t]; tcp_ffi.hosted_ssh_read.restype = c.c_ssize_t
            tcp_ffi.hosted_ssh_write.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t]; tcp_ffi.hosted_ssh_write.restype = c.c_ssize_t
            bridge = c.CDLL(str(bridge_lib))
            bridge.bridge_open.argtypes = [c.c_uint16]; bridge.bridge_open.restype = c.c_bool
            bridge.bridge_poll.restype = c.c_bool
            bridge.bridge_ready.restype = c.c_bool
            bridge.bridge_read.argtypes = [c.c_void_p, c.c_size_t]; bridge.bridge_read.restype = c.c_ssize_t
            bridge.bridge_write.argtypes = [c.c_void_p, c.c_size_t]; bridge.bridge_write.restype = c.c_ssize_t
            bridge.bridge_close_write.restype = c.c_bool
            bridge.bridge_closed.restype = c.c_bool
            # A missing TCP connection is fatal, not nonblocking backpressure.
            assert bridge.bridge_read(c.create_string_buffer(1), 1) == -2
            assert bridge.bridge_write(buffer(b"x"), 1) == -2
        key = tmp / "host"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        pin = hashlib.sha256(base64.b64decode(key.with_suffix(".pub").read_text().split()[1])).digest()
        lifecycle_bad_pin = os.environ.get("NIHOS_SSH_LIFECYCLE_BADPIN") == "1"
        if lifecycle_bad_pin:
            if os.environ.get("NIHOS_SSH_LIFECYCLE") != "1" or not bridge:
                raise ValueError("lifecycle bad-pin control requires lifecycle over libslirp")
            pin = bytes([pin[0] ^ 1]) + pin[1:]
        bad_pin = os.environ.get("NIHOS_SSH_BADPIN") == "1"
        if bad_pin:
            if not (os.environ.get("NIHOS_SSH_AUTOKEX") == "1" or os.environ.get("NIHOS_SSH_AUTOCONNECT") == "1" or os.environ.get("NIHOS_SSH_AUTOCLIENT") == "1") or bridge:
                raise ValueError("bad-pin control requires automatic KEX over a host socket")
            pin = bytes([pin[0] ^ 1]) + pin[1:]
        bad_auth = os.environ.get("NIHOS_SSH_BADAUTH") == "1"
        if bad_auth and (os.environ.get("NIHOS_SSH_AUTOCLIENT") != "1" or bridge or bad_pin):
            raise ValueError("bad-auth control requires automatic client over a host socket")
        with socket.socket() as picker:
            picker.bind(("127.0.0.1", 0)); port = picker.getsockname()[1]
        seed = buffer(os.urandom(32)); user_public = c.create_string_buffer(32)
        assert p.probe_auth_public(seed, user_public)
        authorized = tmp / "authorized_keys"
        authorized.write_bytes(b"ssh-ed25519 " + base64.b64encode(string(b"ssh-ed25519") + string(user_public.raw)) + b"\n")
        if bad_auth: seed = buffer(os.urandom(32))
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
                lifecycle_mode = os.environ.get("NIHOS_SSH_LIFECYCLE") == "1"
                hosted_vt = os.environ.get("NIHOS_SSH_HOSTED_VT") == "1" or lifecycle_mode
                hosted_session = os.environ.get("NIHOS_SSH_HOSTED_SESSION") == "1" or hosted_vt
                if hosted_session and not bridge: raise ValueError("Hosted session requires libslirp")
                auto_client = os.environ.get("NIHOS_SSH_AUTOCLIENT") == "1" or hosted_session
                auto_connect = os.environ.get("NIHOS_SSH_AUTOCONNECT") == "1" or auto_client
                auto_ident = os.environ.get("NIHOS_SSH_AUTOIDENT") == "1"
                if not auto_ident and not auto_connect:
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
                if auto_ident and not auto_connect:
                    deadline = time.monotonic() + (20 if bridge else 5)
                    while True:
                        state = p.probe_ident_poll()
                        if state < 0: raise RuntimeError("SSH identification exchange failed")
                        if state == 1: break
                        if time.monotonic() > deadline: raise TimeoutError("SSH identification timeout")
                        if bridge: time.sleep(0.001)
                        else: select.select([sock], [sock], [], 0.001)
                    value = c.create_string_buffer(253)
                    size = p.probe_ident_banner(value, len(value))
                    if not size: raise RuntimeError("SSH identification missing")
                    server_banner = value.raw[:size]
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
                if lifecycle_mode:
                    username = getpass.getuser().encode()
                elif auto_client:
                    now = time.monotonic_ns() // 1000
                    if hosted_session:
                        assert tcp_ffi.hosted_ssh_begin(buffer(os.urandom(16)), buffer(os.urandom(32)), buffer(pin))
                    else:
                        p.probe_client_begin(buffer(os.urandom(16)), buffer(os.urandom(32)), buffer(pin), now, now + (20_000_000 if bridge else 5_000_000))
                    username = getpass.getuser().encode()
                    while True:
                        if hosted_session:
                            if not bridge.bridge_poll(): raise RuntimeError("TCP bridge failed")
                            state = tcp_ffi.hosted_ssh_poll(buffer(os.urandom(32)), buffer(username), len(username), seed)
                        else:
                            state = p.probe_client_poll(time.monotonic_ns() // 1000, buffer(os.urandom(32)), buffer(username), len(username), seed)
                        if state == -2 and bad_pin:
                            print("SSH client rejected the wrong host pin: OK")
                            return
                        if state == -3 and bad_auth:
                            print("SSH client rejected unauthorized key: OK")
                            return
                        if state < 0: raise RuntimeError(f"SSH client startup failed: {state}")
                        if state == 1:
                            if bad_pin: raise RuntimeError("SSH client accepted the wrong host pin")
                            if bad_auth: raise RuntimeError("SSH client accepted an unauthorized key")
                            break
                        if bridge: time.sleep(0.001)
                        else: select.select([sock], [sock] if p.probe_pending() else [], [], 0.001)
                elif auto_connect:
                    now = time.monotonic_ns() // 1000
                    p.probe_connection_begin(buffer(os.urandom(16)), buffer(os.urandom(32)), buffer(pin), now, now + (20_000_000 if bridge else 5_000_000))
                    while True:
                        state = p.probe_connection_poll(time.monotonic_ns() // 1000, buffer(os.urandom(32)))
                        if state == -2 and bad_pin:
                            print("SSH connection rejected the wrong host pin: OK")
                            return
                        if state < 0: raise RuntimeError("SSH connection failed")
                        if state == 1:
                            if bad_pin: raise RuntimeError("SSH connection accepted the wrong host pin")
                            break
                        if bridge: time.sleep(0.001)
                        else: select.select([sock], [sock] if p.probe_pending() else [], [], 0.001)
                elif os.environ.get("NIHOS_SSH_AUTOKEX") == "1":
                    assert p.probe_driver_begin(buffer(os.urandom(16)), buffer(os.urandom(32)), buffer(pin), buffer(server_banner), len(server_banner))
                    deadline = time.monotonic() + (20 if bridge else 5)
                    while True:
                        state = p.probe_driver_step(buffer(os.urandom(32)))
                        if state == -2 and bad_pin:
                            print("SSH KEX driver rejected the wrong host pin: OK")
                            return
                        if state < 0: raise RuntimeError("SSH KEX driver failed")
                        if state == 1:
                            if bad_pin: raise RuntimeError("SSH KEX driver accepted the wrong host pin")
                            break
                        assert p.probe_poll(), "socket pump failed"
                        if time.monotonic() > deadline: raise TimeoutError("SSH KEX driver timeout")
                        if bridge: time.sleep(0.001)
                        else: select.select([sock], [sock] if p.probe_pending() else [], [], 0.001)
                else:
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
                if not auto_client:
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
                if not auto_client:
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
                if not auto_client:
                    action(0); wait_event(1)
                    action(1); wait_event(2)
                    action(2); wait_event(3)
                if hosted_vt:
                    vt_lib = tmp / ("vt.dylib" if sys.platform == "darwin" else "vt.so")
                    subprocess.run([ZIG, "build-lib", "-dynamic", "-O", "ReleaseSafe", "-femit-bin=" + str(vt_lib),
                        "--dep", "ssh_terminal_session", "--dep", "text_console", "--dep", "terminal_adapter", "--dep", "ssh_lifecycle", "-Mroot=src/xy/ssh_terminal_host_probe.zig",
                        "--dep", "vt100", "--dep", "terminal_buffer", "-Mssh_terminal_session=src/xy/ssh_terminal_session.zig",
                        "--dep", "terminal_adapter", "-Mvt100=src/net/vt100.zig",
                        "--dep", "viewport_layout", "--dep", "terminal_adapter", "--dep", "vt100", "-Mterminal_buffer=src/xy/terminal_buffer.zig",
                        "--dep", "view_config", "-Mviewport_layout=src/graphics/viewport_layout.zig",
                        "-Mterminal_adapter=src/net/terminal_adapter.zig", "-Mview_config=src/xy/view_config.zig",
                        "--dep", "view_config", "--dep", "canvas", "-Mtext_console=src/console.zig",
                        "--dep", "surface", "-Mcanvas=src/graphics/canvas.zig", "-Msurface=src/graphics/surface.zig",
                        "-Mssh_lifecycle=src/xy/ssh_lifecycle.zig"], cwd=ROOT, check=True)
                    vt = c.CDLL(str(vt_lib))
                    poll_cb = c.CFUNCTYPE(c.c_ssize_t, c.c_void_p, c.c_void_p, c.c_size_t, c.c_void_p)
                    io_cb = c.CFUNCTYPE(c.c_ssize_t, c.c_void_p, c.c_void_p, c.c_size_t)
                    @poll_cb
                    def vt_poll_backend(random, user, length, key):
                        return tcp_ffi.hosted_ssh_poll(random, user, length, key)
                    @io_cb
                    def vt_read_backend(random, output, length):
                        return tcp_ffi.hosted_ssh_read(random, output, length)
                    @io_cb
                    def vt_write_backend(random, data, length):
                        return tcp_ffi.hosted_ssh_write(random, data, length)
                    vt.probe_vt_begin.argtypes = [poll_cb, io_cb, io_cb]
                    vt.probe_vt_poll.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_void_p]; vt.probe_vt_poll.restype = c.c_ssize_t
                    vt.probe_vt_key.argtypes = [c.c_uint32]; vt.probe_vt_key.restype = c.c_bool
                    vt.probe_vt_cell.argtypes = [c.c_size_t]; vt.probe_vt_cell.restype = c.c_uint32
                    if lifecycle_mode:
                        action_cb = c.CFUNCTYPE(c.c_bool)
                        start_cb = c.CFUNCTYPE(c.c_bool, c.c_void_p, c.c_void_p, c.c_void_p)
                        @start_cb
                        def lifecycle_start(cookie, secret, host_pin):
                            return tcp_ffi.hosted_ssh_begin(cookie, secret, host_pin)
                        @action_cb
                        def lifecycle_ready(): return bridge.bridge_ready()
                        @action_cb
                        def lifecycle_release():
                            tcp_ffi.hosted_ssh_abort()
                            return True
                        @action_cb
                        def lifecycle_cancel(): return tcp_ffi.tcp_link_cancel()
                        @action_cb
                        def lifecycle_close(): return bridge.bridge_close_write()
                        @action_cb
                        def lifecycle_complete(): return bridge.bridge_closed()
                        vt.probe_lifecycle_begin.argtypes = [poll_cb, io_cb, io_cb, start_cb, action_cb, action_cb, action_cb, action_cb, action_cb, c.c_uint64, c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p]
                        vt.probe_lifecycle_begin.restype = c.c_bool
                        vt.probe_lifecycle_poll.argtypes = [c.c_uint64, c.c_void_p, c.c_void_p, c.c_void_p]
                        vt.probe_lifecycle_poll.restype = c.c_ssize_t
                        vt.probe_profile_cleared.restype = c.c_bool
                        vt.probe_seed_cleared.restype = c.c_bool
                        secret, cookie = buffer(os.urandom(32)), buffer(os.urandom(16))
                        fingerprint = b"SHA256:" + base64.b64encode(pin).rstrip(b"=")
                        seed_hex = seed.raw.hex().encode("ascii")
                        assert vt.probe_lifecycle_begin(vt_poll_backend, vt_read_backend, vt_write_backend, lifecycle_start, lifecycle_ready, lifecycle_release, lifecycle_cancel, lifecycle_close, lifecycle_complete, time.monotonic_ns() // 1000, buffer(username), len(username), buffer(fingerprint), buffer(seed_hex))
                    else:
                        vt.probe_vt_begin(vt_poll_backend, vt_read_backend, vt_write_backend)
                    def vt_step():
                        if not bridge.bridge_poll(): raise RuntimeError("TCP bridge failed")
                        result = (vt.probe_lifecycle_poll(time.monotonic_ns() // 1000, secret, cookie, buffer(os.urandom(32))) if lifecycle_mode else
                                  vt.probe_vt_poll(buffer(os.urandom(32)), buffer(username), len(username), seed))
                        if result < 0 and not (lifecycle_bad_pin and result == -2): raise RuntimeError("VT session failed")
                        time.sleep(0.001)
                        return result
                    deadline = time.monotonic() + 20
                    while True:
                        state = vt_step()
                        if lifecycle_bad_pin and state == -2:
                            assert vt.probe_profile_cleared(), "profile retained after rejection"
                            sock.closed_by_controller = True
                            print("SSH profile rejected the wrong host pin and was cleared: OK")
                            return
                        if state == 1:
                            if lifecycle_bad_pin: raise RuntimeError("SSH profile accepted the wrong host pin")
                            if lifecycle_mode: assert vt.probe_seed_cleared(), "signing seed retained after authentication"
                            break
                        if time.monotonic() > deadline: raise TimeoutError("VT startup timeout")
                    for byte in b"printf ni%s_ssh_ok hos\n":
                        if not vt.probe_vt_key(byte): raise RuntimeError("VT key queue full")
                    deadline = time.monotonic() + 20
                    while True:
                        if vt_step() == 2: raise RuntimeError("VT session closed before output")
                        cells = "".join(chr(vt.probe_vt_cell(i)) for i in range(80 * 24))
                        if "nihos_ssh_ok" in cells: break
                        if time.monotonic() > deadline: raise TimeoutError("VT output timeout")
                    for byte in b"printf '\\033[999999999999999999999999C'; printf '\\rVT_%s_OK\\n' BOUND\n":
                        if not vt.probe_vt_key(byte): raise RuntimeError("VT control sequence queue full")
                    deadline = time.monotonic() + 20
                    while True:
                        if vt_step() == 2: raise RuntimeError("VT session closed during control sequence")
                        cells = "".join(chr(vt.probe_vt_cell(i)) for i in range(80 * 24))
                        if "VT_BOUND_OK" in cells: break
                        if time.monotonic() > deadline: raise TimeoutError("VT control sequence timeout")
                    for byte in b"exit\n":
                        if not vt.probe_vt_key(byte): raise RuntimeError("VT exit queue full")
                    deadline = time.monotonic() + 20
                    while vt_step() != 2:
                        if time.monotonic() > deadline: raise TimeoutError("VT close timeout")
                    if lifecycle_mode:
                        assert vt.probe_profile_cleared(), "profile retained after close"
                        sock.closed_by_controller = True
                elif auto_client:
                    def tty_step():
                        if hosted_session:
                            if not bridge.bridge_poll(): raise RuntimeError("TCP bridge failed")
                            result = tcp_ffi.hosted_ssh_poll(buffer(os.urandom(32)), buffer(username), len(username), seed)
                            result = 1 if result == 2 else 0 if result == 1 else -1
                        else:
                            result = p.probe_terminal_poll(time.monotonic_ns() // 1000, buffer(os.urandom(32)))
                        if result < 0: raise RuntimeError("SSH terminal poll failed")
                        if bridge: time.sleep(0.001)
                        else: select.select([sock], [sock] if p.probe_pending() else [], [], 0.001)
                        return result
                    def tty_write(data):
                        deadline = time.monotonic() + (20 if bridge else 5)
                        while data:
                            count = (tcp_ffi.hosted_ssh_write(buffer(os.urandom(32)), buffer(data), len(data)) if hosted_session else
                                     p.probe_terminal_write(time.monotonic_ns() // 1000, buffer(os.urandom(32)), buffer(data), len(data)))
                            if count < 0: raise RuntimeError("SSH terminal write failed")
                            data = data[count:]
                            if tty_step(): raise RuntimeError("SSH terminal closed while writing")
                            if time.monotonic() > deadline: raise TimeoutError("SSH terminal write timeout")
                    tty_write(b"printf ni%s_ssh_ok hos\n")
                    output = b""
                    deadline = time.monotonic() + (20 if bridge else 5)
                    while b"nihos_ssh_ok" not in output:
                        if tty_step(): raise RuntimeError("SSH terminal closed before output")
                        out = c.create_string_buffer(7)
                        n = (tcp_ffi.hosted_ssh_read(buffer(os.urandom(32)), out, len(out)) if hosted_session else
                             p.probe_terminal_read(time.monotonic_ns() // 1000, buffer(os.urandom(32)), out, len(out)))
                        if n < 0: raise RuntimeError("SSH terminal read failed")
                        output += out.raw[:n]
                        if time.monotonic() > deadline: raise TimeoutError("SSH terminal read timeout")
                    if os.environ.get("NIHOS_SSH_LARGE_OUTPUT") == "1":
                        tty_write(b"python3 -c 'print(\"x\"*70000)'\n")
                        received = 0
                        deadline = time.monotonic() + 30
                        while received < 70000:
                            if tty_step(): raise RuntimeError("SSH terminal closed during large output")
                            out = c.create_string_buffer(257)
                            n = (tcp_ffi.hosted_ssh_read(buffer(os.urandom(32)), out, len(out)) if hosted_session else
                             p.probe_terminal_read(time.monotonic_ns() // 1000, buffer(os.urandom(32)), out, len(out)))
                            if n < 0: raise RuntimeError("SSH terminal large-output read failed")
                            received += out.raw[:n].count(b"x")
                            if time.monotonic() > deadline: raise TimeoutError(f"SSH terminal output stalled at {received} bytes")
                    tty_write(b"exit\n")
                    deadline = time.monotonic() + (20 if bridge else 5)
                    while not tty_step():
                        out = c.create_string_buffer(7)
                        n = (tcp_ffi.hosted_ssh_read(buffer(os.urandom(32)), out, len(out)) if hosted_session else
                             p.probe_terminal_read(time.monotonic_ns() // 1000, buffer(os.urandom(32)), out, len(out)))
                        if n < 0:
                            raise RuntimeError("SSH terminal drain failed")
                        if time.monotonic() > deadline: raise TimeoutError("SSH terminal close timeout")
                else:
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
