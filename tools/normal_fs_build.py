"""Compile the same normal FS service for RV32 and the hosted MMIO probe."""
import hashlib
import json
import os
from pathlib import Path
import platform
import runpy
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(work, native=True, runtime_source=None, sqld_host_test=False):
    if native and sqld_host_test: raise ValueError("host capability fixture cannot enable a native image")
    work = Path(work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    upstream = runpy.run_path(str(ROOT / 'tools/bootstrap-fatfs.py'))
    cache = work / 'fatfs'
    cache.mkdir(exist_ok=True)
    for name, _, _ in upstream['INPUTS']:
        seed = ROOT / '.tools/fatfs-r016-p2' / name
        if seed.is_file():
            shutil.copy2(seed, cache / name)
    source = upstream['bootstrap'](cache)
    zig = ROOT / '.tools/zig-0.17.0/zig'
    if native:
        target = ['-target', 'riscv32-freestanding-none', '-mcpu=generic_rv32+m+a+c+zicsr+zifencei']
    elif platform.system() == 'Darwin':
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
        arch = {'arm64': 'aarch64', 'x86_64': 'x86_64'}[platform.machine()]
        target = ['-target', arch + '-macos.' + sdk, '-fPIC']
    else:
        target = ['-fPIC']
    runtime = work / ('normal_fs_runtime.o' if native else 'normal_fs_runtime.a')
    module = [*target, '-O', 'safe']
    command = [str(zig), 'build-obj' if native else 'build-lib']
    command += ['-fllvm', '-fno-strip', '-fno-stack-check', '-fno-stack-protector', '-fno-unwind-tables'] if native else ['-fcompiler-rt']
    profile = work / 'sqld_profile.zig'
    profile.write_text('pub const enabled = ' + ('true' if (native and os.environ.get('NIHOS_NATIVE_SQLD') == '1') or sqld_host_test else 'false') + ';\npub const provision_cid: u32 = ' + str(int(os.environ.get('NIHOS_NATIVE_SQLD_PROVISION_CID', '0'), 0)) + ';\n')
    command += [*module, '--dep', 'sqld_profile', '--dep', 'storage_vfs', '--dep', 'task_calls', '--dep', 'task_control', '--dep', 'sdmmc', '--dep', 'timer_group', '--dep', 'sdmmc_host',
                '-Mroot=' + str(runtime_source or ROOT / 'src/platform/native/normal_fs.zig'),
                *module, '-Msqld_profile=' + str(profile),
                *module, '-Mstorage_vfs=' + str(ROOT / 'src/storage_vfs.zig'),
                *module, '--dep', 'task_control', '-Mtask_calls=' + str(ROOT / 'src/arch/riscv32/task_calls.zig'),
                *module, '-Mtask_control=' + str(ROOT / 'src/kernel/task_control.zig'),
                *module, '-Msdmmc=' + str(ROOT / 'src/soc/esp32p4/sdmmc.zig'),
                *module, '-Mtimer_group=' + str(ROOT / 'src/soc/esp32p4/timer_group.zig'),
                *module, '-Msdmmc_host=' + str(ROOT / 'src/io/sdmmc_host.zig'), '-femit-bin=' + str(runtime)]
    if native:
        command += ['-femit-llvm-bc=' + str(work / 'normal-fs.bc')]
    subprocess.run(command, cwd=ROOT, check=True)
    if native:
        subprocess.run([str(zig), 'clang', '-cc1', '-x', 'ir', '-triple', 'riscv32-unknown-none', '-target-abi', 'ilp32',
                        '-emit-obj', '-O2', '-Wno-override-module', '-Werror', '-fstack-size-section',
                        str(work / 'normal-fs.bc'), '-o', str(runtime)], check=True)
    cc = [str(zig), 'cc', *target, '-mabi=ilp32'] if native else shlex.split(os.environ.get('CC', 'cc'))
    flags = ['-Oz', '-fno-inline-functions', '-ffreestanding', '-fno-builtin', '-fno-pic', '-ffunction-sections',
             '-fdata-sections', '-fno-stack-protector', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-fstack-size-section'] if native else ['-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    flags += ['-std=c11', '-Wall', '-Wextra', '-Werror', '-I' + str(ROOT / 'include'),
              '-I' + str(ROOT / 'probes/fatfs-disk'), '-I' + str(source),
              '-Dnih_ro_open=nih_fatfs_guard_open', '-Dnih_ro_directory=nih_fatfs_guard_directory',
              '-Dnih_ro_status_name=nih_fatfs_guard_status_name']
    if native:
        headers = ROOT / '.tools/zig-0.17.0/lib/libc/include'
        for folder in ['riscv32-linux-musl', 'generic-musl', 'riscv-linux-any']:
            flags += ['-isystem', str(headers / folder)]
    paths = {'guard': ROOT / 'probes/fatfs-disk/safety.c', 'unicode': source / 'ffunicode.c',
             'backend': ROOT / 'src/storage/fatfs_backend.c', 'disk': ROOT / 'src/storage/fatfs_disk.c',
             'volume': ROOT / 'src/storage/fatfs_volume.c', 'card': ROOT / 'src/platform/native/fatfs_card.c',
             'native_disk': ROOT / 'src/platform/native/fatfs_disk.c'}
    if native:
        paths["strings"] = ROOT / "src/compat/c_strings.c"
    objects = [runtime]
    for name, path in paths.items():
        obj = work / ('normal_fs_' + name + '.o')
        subprocess.run([*cc, *flags, '-c', str(path), '-o', str(obj)], check=True)
        objects.append(obj)
    if native:
        import normal_fs_manifest
        identity = normal_fs_manifest.create(work, source, objects)
        obj = work / 'normal_fs_identity.o'
        subprocess.run([*cc, *flags, '-c', str(identity), '-o', str(obj)], check=True)
        objects.append(obj)
    return objects, source


if __name__ == '__main__':
    objects, source = build(Path(sys.argv[1]), native=True)
    print(json.dumps({'objects': [str(p) for p in objects], 'source': str(source)}))
