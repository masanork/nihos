import hashlib, socket, threading, time

class PeerCapture:
    def __init__(self, peer):
        self.peer = peer
        self.stop = threading.Event()
        self.ready = threading.Event()
        self.records = []
        self.error = None
        self.origin_ns = time.monotonic_ns()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()
        if not self.ready.wait(2):
            raise RuntimeError('peer capture did not start')

    def close(self):
        self.stop.set()
        self.thread.join(2)
        if self.thread.is_alive():
            raise RuntimeError('peer capture did not stop')
        if self.error:
            raise RuntimeError('peer capture failed') from self.error
        return self.records

    def _run(self):
        pending = []
        next_echo = time.monotonic() + 1
        try:
            self.peer.settimeout(.02)
            self.ready.set()
            while not self.stop.is_set():
                try:
                    packet, source = self.peer.recvfrom(65535)
                    stamp = (time.monotonic_ns() - self.origin_ns) // 1000
                    attempt = packet[8] if len(packet) == 1200 else None
                    valid = ((len(packet) in (64, 65) and packet == b'NIHOSUDP' + bytes(range(8,len(packet)))) or
                             (len(packet) == 1200 and packet[:8] == b'NIHOSUDP' and 1 <= packet[8] <= 18 and packet[9:] == bytes(i % 256 for i in range(9,1200))))
                    self.records.append({'event':'received','elapsed_us':stamp,'source_ip':source[0],'source_port':source[1],'bytes':len(packet),'sha256':hashlib.sha256(packet).hexdigest(),'attempt':attempt,'payload_matches':valid})
                    if valid:
                        if len(packet) == 64:
                            pending.append((packet, source))
                        count = self.peer.sendto(packet, source)
                        self.records.append({'event':'echoed','elapsed_us':(time.monotonic_ns()-self.origin_ns)//1000,'bytes':count,'attempt':attempt})
                except socket.timeout:
                    pass
                if pending and time.monotonic() >= next_echo:
                    for payload, destination in pending:
                        count = self.peer.sendto(payload, destination)
                        self.records.append({'event':'echoed_retry','bytes':count})
                    next_echo = time.monotonic() + 1
        except Exception as error:
            self.error = error
            self.ready.set()
