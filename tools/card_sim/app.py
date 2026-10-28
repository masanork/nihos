#!/usr/bin/env python3
"""Local card UI simulator. No serial, USB reader, card or APDU transport."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

if __package__:
    from .backend import LOCK, Simulator
else:
    from backend import LOCK, Simulator


def create_server(sim, port):
    page = Path(__file__).with_name('index.html').read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Never log input samples or request bodies.

        def send(self, code, body, mime='application/json', **headers):
            self.send_response(code)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            for key, value in headers.items():
                self.send_header(key.replace('_', '-'), value)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            with LOCK:
                url = urlsplit(self.path)
                if url.path == '/':
                    self.send(200, page, 'text/html; charset=utf-8')
                elif url.path == '/state':
                    self.send(200, json.dumps(sim.state()).encode())
                elif url.path == '/trace':
                    self.send(200, json.dumps(sim.trace, indent=2).encode(),
                              Content_Disposition='attachment; filename="card-sim-trace.json"')
                elif url.path == '/frame':
                    state = sim.state()
                    expected = parse_qs(url.query).get('sha', [state['pixel_sha256']])[0]
                    if expected != state['pixel_sha256']:
                        self.send(409, b'{"error":"frame changed"}')
                    else:
                        self.send(200, sim.pixels(), 'application/octet-stream', X_Pixel_SHA256=expected)
                else:
                    self.send(404, b'{}')

        def do_POST(self):
            host = f'127.0.0.1:{self.server.server_port}'
            if (self.headers.get('Host') != host or
                    self.headers.get('Origin') not in (None, f'http://{host}') or
                    self.headers.get('Content-Type') != 'application/json'):
                self.send(403, b'{"error":"local JSON requests only"}')
                return
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 131072:
                    raise ValueError('invalid request length')
                data = json.loads(self.rfile.read(size))
                with LOCK:
                    if self.path == '/action':
                        state = sim.action(**data)
                    elif self.path == '/touch':
                        state = sim.touch(**data)
                    elif self.path == '/key':
                        state = sim.key(**data)
                    elif self.path == '/replay':
                        state = sim.replay(data)
                    else:
                        self.send(404, b'{}')
                        return
                    self.send(200, json.dumps(state).encode())
            except (ValueError, TypeError, KeyError):
                self.send(400, b'{"error":"invalid simulator request"}')

    return ThreadingHTTPServer(('127.0.0.1', port), Handler)


def serve(sim, port):
    server = create_server(sim, port)
    print(f'Card UI host simulator: http://127.0.0.1:{server.server_port}', flush=True)
    print('Synthetic data / count-only input / no physical device I/O', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8711)
    parser.add_argument('--headless', type=Path, metavar='OUTPUT', help='run regression scenarios and retain evidence')
    parser.add_argument('--replay', type=Path, help='replay a semantic trace before serving')
    parser.add_argument('--base-audit', type=Path, help='import service_sram extents from a base image audit')
    args = parser.parse_args()
    sim = Simulator(base_audit=args.base_audit)
    if args.headless:
        from scenarios import run
        report = run(sim, args.headless)
        print(json.dumps(report['summary'], ensure_ascii=False))
    else:
        if args.replay:
            sim.replay(json.loads(args.replay.read_text()))
        serve(sim, args.port)


if __name__ == '__main__':
    main()
