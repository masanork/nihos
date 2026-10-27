#!/usr/bin/env python3
"""Separate-process file-image checks; SIGKILL is not a machine power cut."""
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys

CAPACITY = 512 * 1024


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def campaign(binary, output):
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise RuntimeError('Use a new empty output directory')
    probe = output / 'file-probe'
    shutil.copy2(binary, probe)
    result = {'schema': 1, 'evidence': 'host-file-and-process', 'physical_power_cuts': 0,
              'creation': 'exclusive create; fill; file fsync; parent directory fsync',
              'binary_sha256': hashlib.sha256(probe.read_bytes()).hexdigest(),
              'capacity': CAPACITY, 'commands': [], 'cases': [], 'passed': False}

    def run(mode, image, error=None):
        command = [str(probe), mode, str(image)]
        process = subprocess.run(command, capture_output=True, text=True, timeout=15)
        row = {'command': command, 'exit_code': process.returncode,
               'stdout': process.stdout, 'stderr': process.stderr}
        result['commands'].append(row)
        if error is not None:
            if process.returncode == 0 or error not in process.stderr:
                raise RuntimeError('Expected '+error+': '+str(row))
            return None
        if process.returncode != 0:
            raise RuntimeError('Probe failed: '+str(row))
        return json.loads(process.stdout)

    def create(name):
        path = output / name
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            block = b'\xff' * 65536
            written = 0
            while written < CAPACITY:
                n = os.write(descriptor, block[:min(len(block), CAPACITY-written)])
                if n == 0:
                    raise RuntimeError('Image creation made no progress')
                written += n
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        parent = os.open(output, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
        require(run('format', path)['generation'] == 1, 'Wrong initial generation')
        require(run('seed', path)['generation'] == 2, 'Seed not acknowledged')
        require(run('verify-old', path)['generation'] == 2, 'Seed not recovered')
        return path

    def waiting(mode, image, phase):
        process = subprocess.Popen([str(probe), mode, str(image)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 15)
            if not ready:
                raise RuntimeError('Probe readiness timeout')
            line = process.stdout.readline()
            if not line:
                raise RuntimeError('Probe stopped before readiness: '+process.stderr.read())
            row = json.loads(line)
            if row['phase'] != phase:
                raise RuntimeError('Unexpected readiness: '+str(row))
            return process, row
        except BaseException:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)
            raise

    def kill(process, ready):
        process.kill()
        stdout, stderr = process.communicate(timeout=5)
        result['commands'].append({'pid': process.pid, 'readiness': ready,
                                   'exit_code': process.returncode, 'stdout': stdout, 'stderr': stderr})
        if process.returncode != -signal.SIGKILL or stdout or stderr:
            raise RuntimeError('Unexpected killed-process result')

    try:
        normal = create('normal.img')
        committed = run('update', normal)
        require(committed['generation'] == 3 and committed['syncs'] == 2, 'Commit barriers missing')
        require(run('verify-new', normal)['generation'] == 3, 'Normal commit lost')
        result['cases'].append({'name': 'normal_separate_process_reopen', 'generation': 3, 'passed': True})

        pending = create('uncommitted.img')
        process, ready = waiting('stage-wait', pending, 'staged')
        kill(process, ready)
        require(ready['generation'] == 2 and ready['syncs'] == 0, 'Stage unexpectedly committed')
        require(run('verify-old', pending)['generation'] == 2, 'Old view not recovered')
        result['cases'].append({'name': 'kill_before_root_publication', 'generation': 2, 'passed': True})

        acknowledged = create('acknowledged.img')
        process, ready = waiting('commit-wait', acknowledged, 'acknowledged')
        kill(process, ready)
        require(ready['generation'] == 3 and ready['syncs'] == 2, 'Acknowledgement precedes barriers')
        require(run('verify-new', acknowledged)['generation'] == 3, 'Acknowledged generation lost')
        result['cases'].append({'name': 'kill_after_synced_acknowledgement', 'generation': 3, 'passed': True})

        process, ready = waiting('lock-wait', pending, 'locked')
        try:
            run('verify-old', pending, 'WouldBlock')
        finally:
            kill(process, ready)
        require(run('verify-old', pending)['generation'] == 2, 'Old view not recovered')
        result['cases'].append({'name': 'cross_process_writer_lock_and_release', 'passed': True})

        short = output / 'short.img'
        short.write_bytes(b'keep these bytes')
        before = short.read_bytes()
        run('inspect', short, 'WrongSize')
        require(short.read_bytes() == before, 'Wrong-size image was modified')
        missing = output / 'missing.img'
        run('inspect', missing, 'FileNotFound')
        require(not missing.exists(), 'Missing image was created')
        link = output / 'link.img'
        link.symlink_to(pending.name)
        run('inspect', link, 'SymLinkLoop')
        result['cases'].append({'name': 'no_create_truncate_or_symlink_follow', 'passed': True})

        corrupt = output / 'corrupt.img'
        shutil.copy2(pending, corrupt)
        with corrupt.open('r+b', buffering=0) as stream:
            for offset in (0, 4096):
                stream.seek(offset)
                value = stream.read(1)[0] ^ 1
                stream.seek(offset)
                stream.write(bytes([value]))
            os.fsync(stream.fileno())
        before = hashlib.sha256(corrupt.read_bytes()).hexdigest()
        run('inspect', corrupt, 'Corrupt')
        require(hashlib.sha256(corrupt.read_bytes()).hexdigest() == before, 'Corrupt image was modified')
        result['cases'].append({'name': 'corrupt_roots_rejected_without_format', 'passed': True})
        result['passed'] = True
    finally:
        result['images'] = {path.name: {'bytes': path.stat().st_size,
                                      'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                            for path in output.glob('*.img') if not path.is_symlink()}
        (output / 'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({'passed': True, 'cases': len(result['cases']), 'result': str(output/'results.json')}))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: store_file_probe.py BINARY NEW_EMPTY_OUTPUT_DIRECTORY')
    campaign(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
