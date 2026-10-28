"""Pinned native fixture and source boundary; no physical-device attestation."""
import hashlib
import re
import struct

SOURCE = 'embedded sparse/RLE FAT12 fixture; not SD FatFs'
CARD_SOURCE = 'physical SD prefix read twice; operator card swap after embedded fixture'
CARD_SOURCE_INSERTED = 'physical SD prefix read twice; inserted FAT/exFAT card; no littlefs boot probe'
CARD_SOURCE_RPC = 'physical SD native VFS/RPC tasks; cancellation and client stop after fenced sector read'
CARD_SOURCES = ('src/platform/native/fatfs_card.c', 'src/platform/native/fatfs_card_abi.zig',
    'include/nihos_fatfs_card.h', 'src/storage/fatfs_volume.c', 'include/nihos_fatfs_volume.h',
    'src/platform/native/fatfs_disk.c', 'src/platform/native/sdmmc_probe.zig',
    'src/fs/sdmmc_owner.zig', 'include/nihos_storage_io.h')
IMAGE_SHA256 = '297d30b5b9794860f808b88fbf907239015d38cea680af6b5a9d1f45c3817e1d'
SOURCES = (
    'src/platform/native/fatfs_runtime.zig', 'src/platform/native/fatfs_service_abi.zig',
    'src/platform/native/fatfs_fixture.c', 'src/platform/native/fatfs_fixture_disk.c',
    'src/platform/native/broker_runtime.zig', 'src/platform/native/storage_service_abi.zig',
    'src/platform/native/start.S', 'src/arch/riscv32/context_offsets.inc', 'src/platform/native/stack_layout.zig',
    'src/platform/native/main.zig', 'src/platform/native/esp32p4.ld',
    'src/storage/fatfs_backend.c', 'src/storage/fatfs_disk.c',
    'include/nihos_fatfs_backend.h', 'include/nihos_fatfs_disk.h',
    'src/storage_vfs.zig', 'src/fs/vfs.zig', 'src/fs/fatfs_backend.zig',
    'src/fs/vfs_rpc.zig', 'src/fs/vfs_memory.zig', 'src/fs/io_leases.zig', 'src/fs/io_stop.zig',
    'src/kernel/event_latch.zig', 'src/kernel/spsc_ring.zig', 'src/kernel/memory_broker.zig', 'src/kernel/page_pool.zig',
    'src/kernel/development_memory.zig', 'src/arch/riscv32/native_tasks.zig',
    'probes/fatfs-disk/safety.c', 'probes/fatfs-disk/safety.h', 'probes/fatfs-disk/ffconf.h',
    'tools/build-native-elf.sh', 'tools/build-fatfs-native-input.py', 'tools/bootstrap-fatfs.py',
    'tools/native-sqlite-manifest.py', 'tools/check-native-image.py', 'tools/fatfs_native_profile.py',
)
SOURCES_V2 = tuple(path for path in SOURCES if path not in ('src/platform/native/start.S', 'src/arch/riscv32/context_offsets.inc', 'src/platform/native/stack_layout.zig'))
SOURCES_V1 = tuple(path for path in SOURCES_V2 if path != 'src/kernel/event_latch.zig')
UPSTREAM = {
    'ff.c': '3c30280ffe2d0fb19a5241d9ed9f20a2c3911c2861652ebf6ad57f74fb369250',
    'ff.h': '42920ae4d6080bfc2a72d92a9969b5e94eeaff070e5e71d90da9ab6d7d8e158e',
    'ffunicode.c': '3f1632c1f1e64b0b683b0d7e51341b9870728f398604869dd8211f1819509a8e',
    'diskio.h': '1c2b29f53e061c55d43b2e412c3a61320b2621bac7561a05e275514baa44785a',
}
HOOKS = ('nih_storage_runtime_ready', 'nih_storage_register', 'nih_storage_pending',
         'nih_storage_task_exited', 'nih_storage_cancel_requested', 'nih_storage_cleanup_ready', 'nih_storage_retired')
WORDS = {'bound_epoch': 4, 'bounds': 16, 'cancel_requested': 4, 'cleanup': 4, 'enabled': 4,
         'flags': 8, 'handles': 8, 'inflight': 4, 'io_armed': 4, 'notifications': 28,
         'ready': 4, 'retired': 4, 'stale_exits': 4}


def require(ok, reason):
    if not ok:
        raise ValueError('native FatFs: ' + reason)


def validate_profile(config):
    require(isinstance(config, dict) and config.get('version') in (1, 2, 3) and config.get('source') == SOURCE and
            config.get('flash_end') == '0x400d0000' and config.get('c_no_inline') is True, 'invalid fixture profile')
    sources = config.get('sources', {})
    require(isinstance(sources, dict) and set(sources) == set({1: SOURCES_V1, 2: SOURCES_V2, 3: SOURCES}[config['version']]) and all(isinstance(x, str) and re.fullmatch('[0-9a-f]{64}', x)
            for x in sources.values()), 'incomplete source identity')
    f = config.get('fixture', {})
    require(isinstance(f, dict) and f.get('schema') == 1 and f.get('source') == SOURCE and f.get('image_sha256') == IMAGE_SHA256 and
            f.get('image_bytes') == 1048576 and f.get('fixture_id') == int(IMAGE_SHA256[:8], 16) and
            f.get('upstream') == UPSTREAM and f.get('payload_bytes') == 3942 and f.get('index_entries') == 31,
            'unapproved immutable fixture/upstream')
    card = config.get('card')
    if card is not None:
        require(isinstance(card,dict) and card.get('version') in (1,2,3),
                'unapproved physical card profile')
        rpc = card.get('rpc',False)
        require(type(rpc) is bool and (not rpc or card['version']==3), 'invalid card RPC profile')
        require(card.get('charged')==(65536 if rpc else 32768), 'invalid card parent charge')
        mode = card.get('mode','swap')
        expected_source = CARD_SOURCE_RPC if rpc else CARD_SOURCE_INSERTED if mode=='inserted' else CARD_SOURCE
        require(mode in ('swap','inserted') and (not rpc or mode=='inserted') and card.get('source') == expected_source
                and (card['version']>=2 or mode=='swap') and (card['version']==1 or 'mode' in card), 'invalid card boot mode/source')
        sources = card.get('sources', {})
        require(isinstance(sources,dict) and set(sources) == set(CARD_SOURCES) and all(isinstance(x, str) and re.fullmatch('[0-9a-f]{64}',x)
                for x in sources.values()), 'incomplete physical card sources')
    return f


def decode_fixture(payload, index, sectors):
    require(0 < sectors <= 2048 and len(index) % 8 == 0, 'invalid fixture geometry')
    output = bytearray(sectors * 512)
    previous, offset = -1, 0
    for at in range(0, len(index), 8):
        lba, start, length = struct.unpack_from('<IHH', index, at)
        require(previous < lba < sectors and start == offset and length > 0 and length % 2 == 0 and
                start + length <= len(payload), 'invalid sparse index/order/extent')
        written = 0
        for i in range(start, start + length, 2):
            count, value = payload[i:i + 2]
            require(0 < count <= 512 - written, 'invalid RLE run')
            output[lba * 512 + written:lba * 512 + written + count] = bytes([value]) * count
            written += count
        require(written == 512, 'short RLE sector')
        previous, offset = lba, start + length
    require(offset == len(payload), 'unindexed payload')
    return bytes(output)


def audit(config, symbols, sizes, low, high, ro_start, rodata, stack_rows, objects):
    fixture = validate_profile(config)
    if config['version'] >= 3:
        require(symbols.get('nih_native_task_context_bytes') == 128, 'missing/changed task-side trap reserve')
    for name in HOOKS:
        require(low <= symbols.get(name, 0) < high, 'IRQ hook outside SRAM: ' + name)
    for name, size in WORDS.items():
        matches = [key for key in symbols if re.fullmatch('fatfs_runtime[.]' + name + r'(?:[.]\d+)?', key)]
        require(len(matches) == 1, 'missing/duplicate resident notification: ' + name)
        address = symbols[matches[0]]
        require(sizes.get(matches[0]) == size and low <= address < address + size <= high,
                'notification outside SRAM: ' + name)
    key = 'nih_fatfs_native_config'
    address = symbols.get(key, 0)
    require(sizes.get(key) == 32 and ro_start <= address < address + 32 <= ro_start + len(rodata),
            'missing immutable control/layout descriptor')
    layout = struct.unpack_from('<8I', rodata, address - ro_start)
    require(layout[:3] == (1, 0x48008000, 32768) and 0 < layout[3] <= layout[2] and
            layout[4:] == (65536, 4696, 8680, 9984), 'invalid control/parent/client layout')
    blobs = []
    for name, size in (('payload', fixture['payload_bytes']), ('index', fixture['index_entries'] * 8)):
        key = 'nih_fatfs_fixture_' + name
        address = symbols.get(key, 0)
        require(sizes.get(key) == size and ro_start <= address < address + size <= ro_start + len(rodata),
                'fixture outside immutable mapped rodata: ' + name)
        blobs.append(rodata[address - ro_start:address - ro_start + size])
    decoded = decode_fixture(*blobs, fixture['image_bytes'] // 512)
    require(hashlib.sha256(decoded).hexdigest() == IMAGE_SHA256, 'embedded fixture digest mismatch')
    required = {'nih_storage_task_entry', 'nih_storage_runtime_init', 'nih_storage_runtime_finish',
                'nih_fatfs_fixture_after_read', 'nih_fatfs_fixture_read', 'nih_fatfs_fixture_bind',
                'nih_fatfs_backend_mount', 'nih_fatfs_backend_lookup', 'nih_fatfs_backend_read',
                'nih_fatfs_backend_destroy', 'nih_fatfs_guard_open', 'f_open', 'f_read'}
    if config.get('card',{}).get('rpc'):
        required.remove('nih_fatfs_fixture_bind')
        required.update({'nih_fatfs_card_mount','nih_fatfs_card_backend','nih_fatfs_card_path',
                         'nih_fatfs_card_destroy','nih_fatfs_card_reads','nih_fatfs_card_rpc_report'})
    require(required.issubset(symbols), 'missing actual FSD/FatFs functions')
    card_symbols = {'nih_fatfs_card_attempt', 'nih_fatfs_card_read', 'nih_fatfs_volume_probe',
                    'nih_fatfs_native_read', 'nih_storage_fatfs_session_begin', 'nih_storage_fatfs_session_end'}
    if config.get('card') is not None:
        require(card_symbols.issubset(symbols), 'missing actual SD card pipeline')
        if config['card']['version']>=2:
            at=symbols.get('nih_fatfs_card_mode',0)
            require(sizes.get('nih_fatfs_card_mode')==4 and ro_start<=at<at+4<=ro_start+len(rodata), 'missing card mode descriptor')
            expected_mode=2 if config['card'].get('rpc') else int(config['card']['mode']=='inserted')
            require(struct.unpack_from('<I',rodata,at-ro_start)[0]==expected_mode, 'card mode differs from image')
        if config['card'].get('rpc'):
            at=symbols.get('nih_fatfs_card_workspace_bytes',0)
            require(sizes.get('nih_fatfs_card_workspace_bytes')==4 and ro_start<=at<at+4<=ro_start+len(rodata), 'missing card workspace size')
            cbytes=struct.unpack_from('<I',rodata,at-ro_start)[0]
            require(0<cbytes<=32768 and 'nih_fatfs_card_rpc_report' in symbols, 'invalid card RPC layout/functions')
            used=0
            for size in (cbytes,8,8680,9984):used=(used+127)//128*128+size
            require(used<=65536,'card RPC parent overflows')
            config={**config,'card':{**config['card'],'workspace_bytes':cbytes,'rpc_parent_used':used}}
    else:
        require('nih_fatfs_card_attempt' not in symbols and 'nih_fatfs_card_read' not in symbols,
                'card pipeline without source profile')
    require(not {'f_write', 'f_mkfs', 'f_unlink', 'f_rename', 'f_truncate', 'f_mkdir'}.intersection(symbols),
            'FatFs write API linked')
    frames = audit_zig_frames(stack_rows, objects, symbols)
    audit_guard_frames(stack_rows)
    return {**config, 'resident_hooks': {name: hex(symbols[name]) for name in HOOKS},
            'embedded_image_sha256': hashlib.sha256(decoded).hexdigest(),
            'control_bytes': layout[3], 'control_reserve_bytes': layout[2], 'control_start': hex(layout[1]),
            'parent_bytes': layout[4], 'client_frame_bytes': layout[5],
            'static_zig_frames': frames,
            'task_stack_contract': {'worker_bytes': 4096, 'guard_bytes': 16, 'trap_context_bytes': 128,
                'ordinary_sp_budget_bytes': 3952} if config['version'] >= 3 else None,
            'whole_call_stack_qualified': False, 'physical_task_run_qualified': False}


def audit_zig_frames(stack_rows, objects, symbols):
    zig_names = set(objects.get('sql_broker_runtime.o', {}).get('functions', []))
    rows = [row for row in stack_rows if zig_names.intersection(row['functions'])]
    measured = set().union(*(set(row['functions']) for row in rows))
    require(zig_names.intersection(symbols).issubset(measured), 'missing Zig static frame metadata')
    require(rows and max(row['bytes'] for row in rows) <= 1024, 'Zig frame exceeds 1024-byte ceiling')
    return {'records': len(rows), 'ceiling_bytes': 1024, 'maximum_bytes': max(row['bytes'] for row in rows),
            'largest': sorted(rows, key=lambda r: r['bytes'], reverse=True)[:10]}


def audit_guard_frames(rows):
    # FF_USE_LFN=2 places name buffers on the stack. Keep the wrapper's
    # parents/identity/open calls separate so their buffers do not overlap.
    guard = [row for row in rows if 'nih_fatfs_guard_open' in row['functions']]
    require(len(guard) == 1 and guard[0]['bytes'] <= 128, 'guard inlining/frame ceiling violated')
