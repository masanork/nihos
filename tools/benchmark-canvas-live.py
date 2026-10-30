#!/usr/bin/env python3
"""Measure local simulator HTTP event-to-response latency; not device timing."""
import argparse
import json
import statistics
import time
import urllib.request


def get_json(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8713)
    parser.add_argument('--pairs', type=int, default=5, choices=range(1, 21))
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('invalid port')
    base = f'http://127.0.0.1:{args.port}'
    state = get_json(base + '/state')
    start_clicks = state['clicks']
    stamp = state['time_us']
    results = []
    for _ in range(args.pairs):
        for contact in (1, 0):
            stamp += 10000
            payload = json.dumps({'contacts': contact, 'x': 200, 'y': 100, 'time_us': stamp}).encode()
            request = urllib.request.Request(base + '/sample', data=payload, headers={'Content-Type': 'application/json'}, method='POST')
            began = time.perf_counter()
            state = get_json(request)
            elapsed_ms = (time.perf_counter() - began) * 1000
            results.append({'contact': contact, 'elapsed_ms': round(elapsed_ms, 3), 'frame': state['frame'], 'clicks': state['clicks']})
    if state['clicks'] != start_clicks + args.pairs:
        raise RuntimeError('click sequence did not complete; measurement invalid')
    print(json.dumps({'scope': 'local HTTP event-to-response; includes GDB, emulator and PNG conversion; not device latency',
                      'pairs': args.pairs, 'median_ms': round(statistics.median(x['elapsed_ms'] for x in results), 3),
                      'measurements': results}, indent=2))


if __name__ == '__main__': main()
