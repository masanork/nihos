#!/usr/bin/env python3
"""Check headless emulator KEM task logs against the exact audited image."""
import hashlib
import json
import re
import sys
from pathlib import Path

FIELDS = {'status', 'ok', 'peak', 'wrong_epoch', 'repeat', 'canceled', 'captures', 'timers', 'stack_used', 'guards', 'erased', 'released', 'stale', 'stale_notify', 'charged', 'ticks0', 'ticks1', 'ssh_ok', 'ssh_bad_pin', 'ssh_bad_sig', 'ssh_bad_transcript', 'ssh_secret_cleared', 'phase', 'waits', 'delivered', 'negative'}

def require(condition, message):
    if not condition:
        raise ValueError(message)

def check(log, with_psram, negative=0):
    require('NIHOS_PQC_TASK_DONE' in log and 'NIHOS_NATIVE_NORMAL_READY' in log, 'missing completion or normal boot')
    require(not re.search(r'NIHOS_NATIVE_(?:FAIL|PANIC)|NIHOS_PQC_TASK_FAIL', log), 'failure marker')
    runs = re.findall(r'^NIHOS_PQC_TASK (.+)$', log, re.M)
    skips = re.findall(r'^NIHOS_PQC_TASK_SKIP (.+)$', log, re.M)
    if not with_psram:
        require(not runs and skips == ['reason=00000001'], 'no-PSRAM path did not skip before allocation')
        return {'status': 'no_psram_skipped'}
    require(len(runs) == 1 and not skips, 'expected one executed worker and no skip')
    require(re.findall(r'^NIHOS_PQC_HANDOFF (.+)$', log, re.M) == [f'ok=00000001 deadline={int(negative == 3):08x} packet={int(negative != 3):08x}'], 'handoff ownership, verification or deadline failed')
    require(re.findall(r'^NIHOS_PQC_DRIVER (.+)$', log, re.M) == [f'verified={int(negative != 3):08x} reclaimed=00000001'], 'driver worker or reclaim failed')
    tokens = runs[0].split()
    require(len(tokens) == len(FIELDS), 'unexpected field count')
    values = {}
    for token in tokens:
        key, sep, val = token.partition('=')
        require(sep == '=' and key in FIELDS and key not in values and re.fullmatch(r'[0-9a-f]{8}', val), 'invalid worker record')
        values[key] = int(val, 16)
    require(set(values) == FIELDS, 'worker fields differ')
    require(values['negative'] == negative and all(values[k] == 1 for k in ('ok','wrong_epoch','repeat','canceled','guards','erased','released','stale','stale_notify','ssh_secret_cleared','delivered')), 'worker or cleanup failure')
    if negative == 0:
        require(values['status'] == 0 and all(values[k] == 1 for k in ('ssh_ok','ssh_bad_pin','ssh_bad_sig','ssh_bad_transcript')), 'SSH authentication failed')
    elif negative in (1, 2, 4):
        require(values['status'] == 0xffffffa1 and values['ssh_ok'] == 0, 'tampered SSH exchange was accepted')
        if negative == 2:
            require(all(values[k] == 1 for k in ('ssh_bad_pin','ssh_bad_sig','ssh_bad_transcript')), 'wrong-pin run did not reach signature verification')
    else:
        require(negative == 3 and values['status'] == 0xffffff9f and values['ssh_ok'] == 0, 'response timeout was accepted')
    require(values['phase'] == (5 if negative == 3 else 3) and values['waits'] > 0, 'SSH task exchange did not complete its response wait')
    require(values['peak'] == 19232 and 0 < values['stack_used'] < 65536 - 128, 'unexpected arena or stack result')
    require(values['charged'] >= 131072 and all(values[k] > 0 for k in ('captures','timers','ticks0','ticks1')), 'worker scheduling or allocation evidence missing')
    return values

def main():
    if len(sys.argv) != 6 or sys.argv[5] not in ('4M', '0', 'bad-ct', 'bad-pin', 'timeout', 'bad-signature'):
        raise SystemExit('usage: check_task_log.py LOG ELF BIN AUDIT 4M|0|bad-ct|bad-pin|timeout|bad-signature')
    log, elf, image, manifest = [Path(x) for x in sys.argv[1:5]]
    audit = json.loads(manifest.read_text())
    require(hashlib.sha256(elf.read_bytes()).hexdigest() == audit['elf_sha256'], 'ELF digest differs')
    require(hashlib.sha256(image.read_bytes()).hexdigest() == audit['image_sha256'], 'image digest differs')
    require(audit['backend'] == 'native-sram' and audit['memory']['profile'] == 'emulator' and not audit['rtos_linked'], 'unexpected image profile')
    mode = sys.argv[5]
    print(json.dumps(check(log.read_text(), mode != '0', {'bad-ct': 1, 'bad-pin': 2, 'timeout': 3, 'bad-signature': 4}.get(mode, 0)), sort_keys=True))

if __name__ == '__main__':
    main()
