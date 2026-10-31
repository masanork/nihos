#!/usr/bin/env python3
"""Offline pack integrity and real libxy pagination/ownership regression tests."""
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACK = json.loads((ROOT/'assets/xy/library.json').read_text())
HOST_DIR = Path(os.environ.get('XY_MAC_HOST', ROOT/'build/xy-mac/xy-mac-host')).parent


class PackTest(unittest.TestCase):
    def test_pinned_sources_and_book_manuscripts_match_pack(self):
        for path, digest in PACK['bookSourceHashes'].items():
            self.assertEqual(hashlib.sha256((ROOT/path).read_bytes()).hexdigest(), digest, path)
        for name, meta in PACK['externalSources'].items():
            self.assertEqual(hashlib.sha256((ROOT/'third_party/xy-reading'/name).read_bytes()).hexdigest(), meta['sha256'])

    def test_complete_books_resolved_snippets_and_ruby_boundaries(self):
        self.assertEqual([x['id'] for x in PACK['items']], ['tutorial','kusamakura','sicp','nihos'])
        self.assertEqual(len(PACK['items'][1]['sections']), 13)
        self.assertTrue(PACK['items'][1]['sections'][-1]['text'].rstrip().endswith('成就したのである。'))
        self.assertGreaterEqual(len(PACK['items'][3]['sections']), 30)
        for item in PACK['items']:
            self.assertTrue(item['source'] and item['license'])
            for section in item['sections']:
                self.assertNotIn('{{', section['text'])
                body = section['text'].encode()
                end = 0
                for r in section['ruby']:
                    self.assertGreaterEqual(r['start'], end)
                    self.assertLess(r['start'], r['end'])
                    body[:r['start']].decode(); body[r['start']:r['end']].decode()
                    end = r['end']
                    self.assertTrue(r['text'])
        sicp = PACK['items'][2]['sections']
        self.assertIn('(+ 137 349)', sicp[1]['text'])
        self.assertIn('(define (factorial n)\n', sicp[2]['text'])
        self.assertNotIn('factorial_definition', sicp[2]['text'])
        self.assertNotIn('\\begin', sicp[2]['text'])
        book = '\n'.join(s['text'] for s in PACK['items'][3]['sections'])
        self.assertIn('pub const BootInfo = extern struct', book)
        self.assertIn('図の説明：', book)
        figures=[f for s in PACK['items'][3]['sections'] for f in s.get('figures',[])]
        self.assertGreaterEqual(len(figures),20)
        for figure in figures:
            self.assertTrue((ROOT/'docs/book/figures/generated'/figure['file']).is_file())

    def test_portable_reading_fonts_match_pack_and_have_no_missing_characters(self):
        path = ROOT/'assets/xy/fonts'
        manifest = json.loads((path/'manifest.json').read_text())
        self.assertEqual(manifest['library_sha256'], hashlib.sha256((ROOT/'assets/xy/library.json').read_bytes()).hexdigest())
        self.assertEqual(manifest['Mincho_missing'], [])
        self.assertEqual(manifest['Gothic_missing'], [])
        for name, meta in manifest['faces'].items():
            self.assertEqual(hashlib.sha256((path/name).read_bytes()).hexdigest(), meta['sha256'])


class Ruby(c.Structure):
    _fields_ = [(n,c.c_uint32) for n in ('start','end','ruby_start','ruby_end')]


@unittest.skipUnless(sys.platform=='darwin', 'C ABI uses the Mac build')
class ReaderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vm = v = c.CDLL(str(HOST_DIR/'libxy_host.dylib'))
        cls.callback = c.CFUNCTYPE(c.c_uint32,c.c_void_p,c.c_uint32,c.c_void_p,c.c_uint32)
        class Desc(c.Structure):
            _fields_ = [('ctx',c.c_void_p),('read',cls.callback)]
        fonts = []
        for family in ('Mincho','Gothic'):
            for layer in ('',):
                fonts.append((ROOT/f'assets/xy/fonts/Bunsen{family}{layer}-Regular.ttf').read_bytes())
        cls.fonts = fonts
        def read(ctx, off, dest, length):
            data = fonts[int(ctx)-1][off:off+length]
            c.memmove(dest,data,len(data)); return len(data)
        cls.read = cls.callback(read)
        cls.mincho = (Desc*1)(Desc(1,cls.read))
        cls.gothic = (Desc*1)(Desc(2,cls.read))
        v.xy_host_init.argtypes = [c.POINTER(Desc),c.c_uint32,c.POINTER(Desc),c.c_uint32]
        v.xy_host_init.restype = c.c_bool
        v.xy_host_eval.argtypes = [c.c_char_p,c.c_uint32,c.c_void_p,c.c_uint32]
        v.xy_host_document_load.argtypes = [c.c_char_p,c.c_uint32]
        v.xy_host_document_load.restype = c.c_bool
        v.xy_host_reader_enter.restype = c.c_bool
        v.xy_host_reader_load.argtypes = [c.c_char_p,c.c_uint32,c.c_char_p,c.c_uint32,c.POINTER(Ruby),c.c_uint32]
        v.xy_host_buffer_copy.argtypes = [c.c_void_p,c.c_uint32]
        v.xy_host_insert_text.argtypes = [c.c_char_p,c.c_uint32]
        v.xy_host_insert_text.restype = c.c_bool
        v.xy_host_render_rgba8.argtypes = [c.c_void_p,c.c_uint32,c.c_uint32,c.c_uint32,c.c_uint8]

    def setUp(self):
        self.assertTrue(self.vm.xy_host_init(self.mincho,1,self.gothic,1))
        self.vm.xy_host_set_viewport(1280,720)

    def eval(self, command):
        b=command.encode(); out=c.create_string_buffer(256)
        return self.vm.xy_host_eval(b,len(b),out,len(out))

    def buffer(self):
        out=c.create_string_buffer(16384)
        n=self.vm.xy_host_buffer_copy(out,len(out)); self.assertGreaterEqual(n,0)
        return out.raw[:n]

    def page(self, section, start=0):
        text=section['text']; data=text.encode()
        end=start+len(data[start:].decode()[:700].encode())
        count=0
        for r in section['ruby']:
            if start<=r['start']<end:
                count+=1
                if count>64: end=r['start']
            if r['start']<end<r['end']: end=r['start']
        spans=[]; readings=b''
        for r in section['ruby']:
            if start<=r['start']<r['end']<=end:
                b=r['text'].encode()
                spans.append(Ruby(r['start']-start,r['end']-start,len(readings),len(readings)+len(b)))
                readings+=b
        array=(Ruby*len(spans))(*spans)
        n=self.vm.xy_host_reader_load(data[start:end],end-start,readings,len(readings),array,len(spans))
        self.assertGreater(n,0,(section['title'],start,end,n))
        self.assertLessEqual(n,end-start)
        self.assertEqual(self.buffer(),data[start:start+n])
        for r in section['ruby']:
            self.assertFalse(r['start']<start+n<r['end'])
        return start+n

    def test_read_only_pages_restore_document_and_undo_exactly(self):
        self.assertGreaterEqual(self.eval('(buffer/insert! "葛󠄀original")'),0)
        saved=self.buffer()
        self.assertTrue(self.vm.xy_host_reader_enter())
        self.page(PACK['items'][1]['sections'][0])
        page=self.buffer()
        self.assertFalse(self.vm.xy_host_insert_text(b'bad',3))
        self.assertFalse(self.vm.xy_host_handle_key(ord('a')))
        self.assertLess(self.eval('(buffer/clear!)'),0)
        self.assertFalse(self.vm.xy_host_document_load(b'bad',3))
        self.assertEqual(self.buffer(),page)
        self.vm.xy_host_reader_leave()
        self.assertEqual(self.buffer(),saved)
        self.assertGreaterEqual(self.eval('(buffer/undo!)'),0)
        self.assertEqual(self.buffer(),b'')

    def test_every_chapter_opens_in_both_axes_at_small_and_large_sizes(self):
        self.assertTrue(self.vm.xy_host_reader_enter())
        pixels=c.create_string_buffer(1280*720*4)
        for axis in ('horizontal','vertical'):
            for size in (24,64):
                self.assertGreaterEqual(self.eval(f"(view/set! #:size {size} #:direction '{axis} #:line-gap 18)"),0)
                for item in PACK['items']:
                    for section in item['sections']:
                        with self.subTest(item=item['id'],section=section['title'],axis=axis,size=size):
                            self.page(section)
                self.assertGreater(self.vm.xy_host_render_rgba8(pixels,1280,720,5120,0),0)
        self.vm.xy_host_reader_leave()

    def test_full_first_chapter_has_no_missing_or_repeated_bytes_and_reflows(self):
        self.assertTrue(self.vm.xy_host_reader_enter())
        section=PACK['items'][1]['sections'][0]
        start=0; chunks=[]; pages=0
        while start<len(section['text'].encode()):
            end=self.page(section,start)
            chunks.append(self.buffer()); start=end; pages+=1
            self.assertLess(pages,500)
        self.assertEqual(b''.join(chunks),section['text'].encode())
        for axis in ('horizontal','vertical'):
            self.eval(f"(view/set! #:size 64 #:direction '{axis})")
            end=self.page(section,0)
            self.assertGreater(end,0)
        self.vm.xy_host_reader_leave()

    def test_horizontal_latin_wraps_by_advance_not_a_full_width_cjk_cell(self):
        self.assertTrue(self.vm.xy_host_reader_enter())
        self.eval("(view/set! #:size 32 #:direction 'horizontal)")
        text='This is a long English paragraph that must occupy several lines. '*12
        end=self.page({'title':'latin wrap','text':text,'ruby':[]})
        self.assertGreater(end,300)
        self.vm.xy_host_reader_leave()

    def test_malformed_page_is_atomic(self):
        self.assertTrue(self.vm.xy_host_reader_enter())
        self.page(PACK['items'][0]['sections'][0]); saved=self.buffer()
        bad=(Ruby*1)(Ruby(0,99,0,3))
        self.assertLess(self.vm.xy_host_reader_load(b'abc',3,b'abc',3,bad,1),0)
        self.assertEqual(self.buffer(),saved)
        self.assertLess(self.vm.xy_host_reader_load(b'\xff',1,b'',0,(Ruby*0)(),0),0)
        self.assertEqual(self.buffer(),saved)
        self.vm.xy_host_reader_leave()

if __name__=='__main__': unittest.main()
