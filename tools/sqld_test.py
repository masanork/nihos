#!/usr/bin/env python3
"""Real SQLite -> checkpoint VFS -> host media, Scheme and failure boundaries."""
import ctypes as c
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
import time
import os

ROOT = Path(__file__).resolve().parents[1]
LIB_PATH = ROOT / 'build/sqld' / ('libsqld.dylib' if sys.platform == 'darwin' else 'libsqld.so')
if not LIB_PATH.is_file():
    if __name__ == '__main__':
        raise SystemExit('Build tools/build-sqld-host.sh before running sqld_test.py')
    raise unittest.SkipTest('sqld has its own required build/test CI job')
LIB = c.CDLL(str(LIB_PATH))


class Request(c.Structure):
    _fields_ = [(n, c.c_uint32) for n in ('epoch', 'sequence', 'operation', 'handle', 'offset', 'length', 'count')] + [('text', c.c_char * 512), ('argument', c.c_char * 64)]


class Response(c.Structure):
    _fields_ = [('epoch', c.c_uint32), ('sequence', c.c_uint32), ('status', c.c_int32), ('sqlite_code', c.c_int32), ('outcome', c.c_uint32), ('length', c.c_uint32), ('text', c.c_char * 1024)]


LIB.nih_sqld_host_open.argtypes = [c.c_char_p, c.c_int]
LIB.nih_sqld_host_open.restype = c.c_void_p
LIB.nih_sqld_host_close.argtypes = [c.c_void_p]
LIB.nih_sqld_host_call.argtypes = [c.c_void_p, c.POINTER(Request), c.POINTER(Response)]
LIB.nih_sqld_host_service.argtypes = [c.c_void_p]
LIB.nih_sqld_host_service.restype = c.c_void_p
LIB.nih_sqld_submit.argtypes = [c.c_void_p, c.c_uint32, c.POINTER(Request)]
LIB.nih_sqld_take.argtypes = [c.c_void_p, c.c_uint32, c.POINTER(Response)]
LIB.nih_sqld_step.argtypes = [c.c_void_p]
LIB.nih_sqld_cancel.argtypes = [c.c_void_p, c.c_uint32, c.c_uint32, c.c_uint32]


def request(op, text=b'', handle=0, offset=0, count=0, argument=b''):
    if isinstance(text, str):
        text = text.encode()
    q = Request(operation=op, handle=handle, offset=offset, count=count, length=len(text), argument=argument)
    c.memmove(c.addressof(q) + Request.text.offset, text, len(text))
    return q


class ServiceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nihos-sqld-')
        self.path = Path(self.temp.name) / 'store'
        self.h = LIB.nih_sqld_host_open(bytes(self.path), 1)
        self.assertTrue(self.h)

    def tearDown(self):
        if self.h:
            self.assertEqual(LIB.nih_sqld_host_close(self.h), 0)
        self.temp.cleanup()

    def call(self, op, text=b'', ok=True, **kw):
        q = request(op, text, **kw)
        r = Response()
        rc = LIB.nih_sqld_host_call(self.h, c.byref(q), c.byref(r))
        if ok:
            self.assertEqual(rc, 0, (rc, r.sqlite_code, bytes(r.text)))
        else:
            self.assertNotEqual(rc, 0)
        return r

    def test_sql_transaction_restart_and_typed_query(self):
        self.call(2, 'CREATE TABLE notes(id INTEGER PRIMARY KEY,body TEXT)')
        self.call(3)
        self.call(2, "INSERT INTO notes VALUES(1,'日本語')")
        self.call(5)
        self.assertEqual(self.call(1, 'SELECT * FROM notes').text, b'()')
        self.call(3)
        self.call(2, "INSERT INTO notes VALUES(1,'日本語')")
        self.assertEqual(self.call(4).outcome, 1)
        self.assertEqual(LIB.nih_sqld_host_close(self.h), 0)
        self.h = LIB.nih_sqld_host_open(bytes(self.path), 0)
        self.assertTrue(self.h)
        self.assertEqual(self.call(22, 'notes', count=2, argument='日本'.encode()).text, '((1 "日本語"))'.encode())
        self.assertEqual(self.call(1, 'SELECT * FROM notes').text, '((1 "日本語"))'.encode())

    def test_files_binary_rollback_remove_resize_and_namespace(self):
        f = int(self.call(6, 'draft.scm', offset=1).text)
        self.call(8, b'\0\xffabc', handle=f)
        self.assertEqual(self.call(7, handle=f, count=5).text, b'(0 255 97 98 99)')
        self.call(11)
        self.call(8, 'changed', handle=f)
        self.call(12)
        self.call(7, handle=f, count=5, ok=False)
        f = int(self.call(6, 'draft.scm').text)
        self.assertEqual(self.call(20, handle=f).text, b'5')
        self.call(9, handle=f, offset=2)
        self.call(11)
        self.assertEqual(self.call(7, handle=f, count=5).text, b'(0 255)')
        self.assertEqual(self.call(18).text, b'("draft.scm")')
        self.call(19, handle=f)
        self.call(20, handle=f, ok=False)
        f = int(self.call(6, 'draft.scm').text)
        self.call(10, handle=f)
        self.call(11)
        self.assertEqual(self.call(18).text, b'()')
        self.call(6, 'draft.scm', ok=False)

    def test_snapshot_restore_is_new_generation_and_stales_handles(self):
        self.call(2, 'CREATE TABLE notes(id INTEGER PRIMARY KEY,body TEXT)')
        self.call(2, "INSERT INTO notes VALUES(1,'before')")
        f = int(self.call(6, 'draft', offset=1).text)
        self.call(8, 'before', handle=f)
        self.call(11)
        snap = int(self.call(13).text)
        self.call(2, "UPDATE notes SET body='after'")
        self.call(8, 'after!', handle=f)
        self.call(11)
        generation = int(self.call(17).text)
        self.call(14, handle=snap)
        self.assertGreater(int(self.call(17).text), generation)
        self.assertEqual(self.call(1, 'SELECT body FROM notes').text, b'(("before"))')
        self.call(7, handle=f, count=6, ok=False)
        f2 = int(self.call(6, 'draft').text)
        self.assertNotEqual(f, f2)
        self.assertEqual(self.call(7, handle=f2, count=6).text, b'(98 101 102 111 114 101)')
        self.call(15, handle=snap)
        self.call(14, handle=snap, ok=False)
        self.assertEqual(self.call(20, handle=f2).text, b'6')
        self.call(16)

    def test_full_handle_table_does_not_revoke_live_handles(self):
        first = int(self.call(6, 'one', offset=1).text)
        self.call(8, 'kept', handle=first)
        self.call(11)
        handles = [first] + [int(self.call(6, 'one').text) for _ in range(15)]
        self.call(6, 'one', ok=False)
        self.assertEqual(self.call(7, handle=first, count=4).text, b'(107 101 112 116)')
        for handle in handles:
            self.call(19, handle=handle)
        newer = int(self.call(6, 'one').text)
        self.assertGreater(newer, max(handles))

    @unittest.skipUnless(sys.platform == 'darwin', 'Mac shared Scheme CLI')
    def test_document_save_and_load_in_separate_processes(self):
        self.assertEqual(LIB.nih_sqld_host_close(self.h), 0)
        self.h = None
        host = ROOT / 'build/xy-mac/xy-mac-host'
        save = '(buffer/insert! "日本語 source") (buffer/save! "source.scm")'
        for source, expected in [(save, '#t\n'), ('(buffer/load! "source.scm") (buffer/text)', '"日本語 source"\n')]:
            result = subprocess.run([str(host), '--storage-cli', str(self.path), source], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)

    def test_policy_and_limits_reject_without_poisoning_service(self):
        for op, text in [(1, 'CREATE TABLE forbidden(x)'), (2, 'PRAGMA synchronous=OFF'), (2, "ATTACH 'evil' AS other"), (2, 'BEGIN'), (2, 'CREATE TABLE a(x); CREATE TABLE b(x)')]:
            self.call(op, text, ok=False)
        self.assertEqual(self.call(1, 'SELECT 42').text, b'((42))')
        self.call(1, 'SELECT 2147483648', ok=False)
        self.call(1, "SELECT printf('%100s','x')", ok=False)
        self.call(1, 'WITH RECURSIVE t(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM t WHERE x<9)SELECT x FROM t', ok=False)
        for name in ('../escape', '/absolute', '..', 'main.db-journal/escape'):
            self.call(6, name, offset=1, ok=False)
        self.assertEqual(self.call(18).text, b'()')
        self.call(2, 'CREATE TABLE a(x)')
        self.call(2, 'INSERT INTO a VALUES(1) RETURNING x', ok=False)
        self.assertEqual(self.call(1, 'SELECT count(*) FROM a').text, b'((0))')

    def test_sqlite_full_keeps_all_acknowledged_rows_and_integrity(self):
        self.call(2, 'CREATE TABLE large(value)')
        acknowledged = 0
        for _ in range(400):
            q, reply = request(2, 'INSERT INTO large VALUES(zeroblob(3500))'), Response()
            rc = LIB.nih_sqld_host_call(self.h, c.byref(q), c.byref(reply))
            if rc:
                self.assertEqual(reply.sqlite_code & 255, 13)  # SQLITE_FULL
                break
            self.assertEqual(reply.outcome, 1)
            acknowledged += 1
        else:
            self.fail('The fixed 1 MiB per-file limit was not enforced')
        self.assertGreater(acknowledged, 0)
        self.assertEqual(self.call(1, 'SELECT count(*) FROM large').text, f'(({acknowledged}))'.encode())
        self.assertEqual(self.call(23).text, b'(("ok"))')

    def test_owner_principal_epoch_queue_backpressure_and_cancel(self):
        service = LIB.nih_sqld_host_service(self.h)
        q = request(1, 'SELECT 42')
        q.epoch, q.sequence = 1, 1
        self.assertEqual(LIB.nih_sqld_submit(service, 8, c.byref(q)), -13)
        q.epoch = 2
        self.assertEqual(LIB.nih_sqld_submit(service, 7, c.byref(q)), -9)
        q.epoch = 1
        for seq in range(1, 5):
            q.sequence = seq
            self.assertEqual(LIB.nih_sqld_submit(service, 7, c.byref(q)), 0)
        q.sequence = 5
        self.assertEqual(LIB.nih_sqld_submit(service, 7, c.byref(q)), -16)
        foreign = []
        thread = threading.Thread(target=lambda: foreign.append(LIB.nih_sqld_step(service)))
        thread.start(); thread.join()
        self.assertEqual(foreign, [-13])
        self.assertEqual(LIB.nih_sqld_cancel(service, 7, 1, 2), 0)
        for _ in range(4):
            self.assertEqual(LIB.nih_sqld_step(service), 1)
        self.assertEqual(LIB.nih_sqld_step(service), 0)
        results = []
        for _ in range(4):
            r = Response()
            self.assertEqual(LIB.nih_sqld_take(service, 7, c.byref(r)), 1)
            results.append((r.sequence, r.status))
        self.assertEqual(results, [(1, 0), (2, -125), (3, 0), (4, 0)])
        self.assertEqual(LIB.nih_sqld_submit(service, 7, c.byref(q)), 0)
        self.assertEqual(LIB.nih_sqld_submit(service, 7, c.byref(q)), -9)
        self.assertEqual(LIB.nih_sqld_step(service), 1)
        self.assertEqual(LIB.nih_sqld_take(service, 7, c.byref(Response())), 1)

    def test_exclusive_existing_image_and_no_destructive_fallback(self):
        before = self.path.read_bytes()
        self.assertFalse(LIB.nih_sqld_host_open(bytes(self.path), 1))
        self.assertFalse(LIB.nih_sqld_host_open(bytes(self.path), 0))
        self.assertEqual(before, self.path.read_bytes())
        corrupt = Path(self.temp.name) / 'corrupt'
        corrupt.write_bytes(bytes(4 * 1024 * 1024))
        self.assertFalse(LIB.nih_sqld_host_open(bytes(corrupt), 0))
        self.assertEqual(corrupt.read_bytes(), bytes(4 * 1024 * 1024))

    def test_transaction_lease_expires_and_reports_timeout(self):
        self.call(2, 'CREATE TABLE a(x)')
        self.call(3)
        self.call(2, 'INSERT INTO a VALUES(1)')
        time.sleep(2.05)
        self.assertEqual(self.call(4, ok=False).status, -110)
        self.assertEqual(self.call(1, 'SELECT count(*) FROM a').text, b'((0))')

    @unittest.skipUnless(sys.platform == 'darwin', 'Cocoa ABI test')
    def test_scheme_calls_real_service_and_restores_both_sql_and_file(self):
        vm = c.CDLL(str(ROOT / 'build/xy-mac/libxy_host.dylib'))
        vm.xy_host_live_init.restype = c.c_bool
        vm.xy_host_set_storage_callback.argtypes = [c.c_void_p, c.c_void_p]
        vm.xy_host_live_run.argtypes = [c.c_char_p, c.c_uint32, c.c_bool, c.c_void_p, c.c_uint32]
        self.assertTrue(vm.xy_host_live_init())
        callback_type = c.CFUNCTYPE(c.c_int32, c.c_void_p, c.c_uint32, c.c_uint32, c.c_uint32, c.c_uint32, c.c_void_p, c.c_uint32, c.c_void_p, c.c_uint32, c.c_void_p, c.c_uint32)
        LIB.nih_sqld_host_xy.argtypes = list(callback_type._argtypes_)
        def trace(*args):
            result = LIB.nih_sqld_host_xy(*args)
            if os.environ.get('NIHOS_SQLD_TRACE'):
                print(args[1:5], c.string_at(args[5], args[6]), result, c.string_at(args[9], max(result, 0)), flush=True)
            return result
        callback = callback_type(trace)
        vm.xy_host_set_storage_callback(self.h, c.cast(callback, c.c_void_p))
        self.addCleanup(vm.xy_host_set_storage_callback, None, None)
        def evaluate(source, expected=None, ok=True):
            encoded = source.encode(); out = c.create_string_buffer(2048)
            n = vm.xy_host_live_run(encoded, len(encoded), False, out, len(out))
            if ok:
                error = c.create_string_buffer(256)
                vm.xy_host_live_error(error, len(error))
                self.assertGreaterEqual(n, 0, (source, error.value))
                if expected is not None: self.assertEqual(out.raw[:n], expected.encode())
            else: self.assertLess(n, 0)
        evaluate('(sql/exec! "CREATE TABLE notes(id PRIMARY KEY,body)")')
        evaluate('(sql/exec! "INSERT INTO notes VALUES(1,\'before\')")')
        evaluate('(define f (fs/open "draft" #t))')
        evaluate('(fs/write! f 0 (list 0 255 1))', '3')
        evaluate('(fs/sync!)')
        evaluate('(define snapshot (fs/snapshot))')
        evaluate('(sql/exec! "UPDATE notes SET body=\'after\'")')
        evaluate('(q \'notes #:where "after" #:limit 1)', '((1 "after"))')
        evaluate('(fs/restore! snapshot)')
        evaluate('(q \'notes #:limit 1)', '((1 "before"))')
        evaluate('(fs/read f 0 3)', ok=False)
        evaluate('(define f (fs/open "draft"))')
        evaluate('(fs/read f 0 3)', '(0 255 1)')
        evaluate('(fs/release! snapshot)')
        evaluate('(fs/collect!)')
        evaluate('(fs/space)')
        evaluate('(sql/check)', '(("ok"))')
        evaluate('(fs/verify f)')
        evaluate('(buffer/insert! "日本語 source")')
        evaluate('(buffer/save! "source.scm")')
        evaluate('(buffer/insert! " unsaved")')
        evaluate('(buffer/load! "source.scm")')
        vm.xy_host_buffer_copy.argtypes = [c.c_void_p, c.c_uint32]
        copied = c.create_string_buffer(256)
        n = vm.xy_host_buffer_copy(copied, len(copied))
        self.assertEqual(copied.raw[:n], '日本語 source'.encode())
        evaluate('(fs/close! f)')
        evaluate('(fs/read f 0 3)', ok=False)


Read = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_uint64, c.c_void_p, c.c_size_t)
Write = Read
Sync = c.CFUNCTYPE(c.c_int, c.c_void_p)
Identity = c.CFUNCTYPE(c.c_uint32, c.c_void_p)
Random = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p, c.c_int)
Clock = c.CFUNCTYPE(c.c_int64, c.c_void_p)
Sleep = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_int)


class Device(c.Structure):
    _fields_ = [('context', c.c_void_p), ('read', Read), ('write', Write), ('sync', Sync)]


class Platform(c.Structure):
    _fields_ = [('context', c.c_void_p), ('identity', Identity), ('random', Random), ('time', Clock), ('sleep', Sleep), ('monotonic', Clock)]


LIB.nih_store_mount.argtypes = [c.c_void_p, c.c_size_t, c.POINTER(Device), c.c_int]
LIB.nih_sqld_start.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.POINTER(Platform), c.c_uint32, c.c_uint32]
LIB.nih_sqld_call.argtypes = [c.c_void_p, c.c_uint32, c.POINTER(Request), c.POINTER(Response)]
LIB.nih_sqld_stop.argtypes = [c.c_void_p]


class MemoryService:
    """Unfenced writes can disappear, persist, or tear at a failed callback.
    Media barriers flush the entire cache. This is a model, not SD firmware."""
    def __init__(self, stable=None):
        self.stable = bytearray(stable if stable is not None else b'\xff' * (4 * 1024 * 1024))
        self.cache = self.stable.copy()
        self.events = 0
        self.cut = None
        self.background = False
        self.failed = False
        self.service = c.create_string_buffer(LIB.nih_sqld_size())
        self.store = c.create_string_buffer(LIB.nih_store_size())
        def read(_, offset, out, n):
            if offset + n > len(self.cache): return -1
            c.memmove(out, bytes(self.cache[offset:offset + n]), n)
            return 0
        def write(_, offset, data, n):
            if self.failed: return -1
            cut = self.events == self.cut
            self.events += 1
            amount = min(31, n) if cut else n
            value = c.string_at(data, amount)
            self.cache[offset:offset + amount] = value
            if self.background: self.stable[offset:offset + amount] = value
            if cut: self.failed = True; return -1
            return 0
        def sync(_):
            if self.failed: return -1
            cut = self.events == self.cut
            self.events += 1
            if cut: self.failed = True; return -1
            self.stable[:] = self.cache
            return 0
        self.device = Device(None, Read(read), Write(write), Sync(sync))
        self.platform = Platform(None, Identity(lambda _: 1), Random(lambda _, p, n: (c.memset(p, 7, n), n)[1]), Clock(lambda _: 210866760000000), Sleep(lambda _, us: us), Clock(lambda _: int(time.monotonic() * 1000)))
        rc = LIB.nih_store_mount(self.store, len(self.store), c.byref(self.device), int(stable is None))
        if rc: raise AssertionError(('mount', rc))
        rc = LIB.nih_sqld_start(self.service, len(self.service), self.store, c.byref(self.platform), 7, 1)
        if rc: raise AssertionError(('start', rc))
        self.events = 0

    def call(self, op, text=''):
        q, r = request(op, text), Response()
        rc = LIB.nih_sqld_call(self.service, 7, c.byref(q), c.byref(r))
        return rc, r

    def close(self, crash=False):
        if crash: self.failed = True  # No cleanup write may repair the crash image.
        return LIB.nih_sqld_stop(self.service)


class CrashTest(unittest.TestCase):
    def test_io_failure_completes_every_already_accepted_request(self):
        live = MemoryService()
        self.assertEqual(live.call(2, 'CREATE TABLE a(x)')[0], 0)
        live.cut = live.events
        # call() used sequence 1, so queued work starts at sequence 2.
        for seq in range(2, 6):
            q = request(2 if seq == 2 else 1, 'INSERT INTO a VALUES(1)' if seq == 2 else 'SELECT 42')
            q.epoch, q.sequence = 1, seq
            self.assertEqual(LIB.nih_sqld_submit(live.service, 7, c.byref(q)), 0)
        for _ in range(4):
            self.assertEqual(LIB.nih_sqld_step(live.service), 1)
        for seq in range(2, 6):
            r = Response()
            self.assertEqual(LIB.nih_sqld_take(live.service, 7, c.byref(r)), 1)
            self.assertEqual((r.sequence, r.outcome), (seq, 2))
            self.assertNotEqual(r.status, 0)
        live.close(crash=True)

    def test_real_sqlite_journal_db_barriers_and_torn_store_publications(self):
        initial = MemoryService()
        self.assertEqual(initial.call(2, 'CREATE TABLE bank(id PRIMARY KEY,value)')[0], 0)
        self.assertEqual(initial.call(2, 'INSERT INTO bank VALUES(1,40),(2,60)')[0], 0)
        self.assertEqual(initial.close(), 0)
        baseline = initial.stable
        update = 'UPDATE bank SET value=CASE id WHEN 1 THEN 41 ELSE 59 END'
        full = MemoryService(baseline)
        rc, reply = full.call(2, update)
        self.assertEqual((rc, reply.outcome), (0, 1))
        event_count = full.events
        self.assertGreater(event_count, 0)
        acknowledged = full.stable.copy()
        full.close(crash=True)
        reopened = MemoryService(acknowledged)
        self.assertEqual(reopened.call(1, 'SELECT value FROM bank ORDER BY id')[1].text, b'((41) (59))')
        reopened.close()
        cases = 0
        for background in (False, True):
            for event in range(event_count):
                with self.subTest(background=background, event=event):
                    live = MemoryService(baseline)
                    live.background, live.cut = background, event
                    rc, reply = live.call(2, update)
                    self.assertNotEqual(rc, 0)
                    self.assertEqual(reply.outcome, 2)
                    self.assertNotEqual(live.call(1, 'SELECT 1')[0], 0)
                    crashed = live.stable.copy()
                    live.close(crash=True)
                    recovered = MemoryService(crashed)
                    self.assertEqual(recovered.call(23)[1].text, b'(("ok"))')
                    rc, rows = recovered.call(1, 'SELECT value FROM bank ORDER BY id')
                    self.assertEqual(rc, 0)
                    self.assertIn(rows.text, (b'((40) (60))', b'((41) (59))'))
                    self.assertEqual(recovered.call(1, 'SELECT sum(value) FROM bank')[1].text, b'((100))')
                    recovered.close()
                    cases += 1
        print(f'SQLITE_CHECKPOINT_CRASH events={event_count} cases={cases}', flush=True)


if __name__ == '__main__':
    unittest.main()
