#!/usr/bin/env python3
"""Actual Tab5 scenes on the host: ROM bounds, pages, touch and reflow."""
import ctypes as c
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/xy-tab5-preview'

class DeviceReader(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data=(OUT/'xy-reading.pack').read_bytes()
        cls.owner=c.create_string_buffer(cls.data)
        cls.vm=v=c.CDLL(str(OUT/('libxy_tab5.dylib' if sys.platform=='darwin' else 'libxy_tab5.so')))
        v.xy_tab5_init.argtypes=[c.c_void_p,c.c_uint32];v.xy_tab5_init.restype=c.c_bool
        v.xy_tab5_render.argtypes=[c.c_void_p,c.c_uint32];v.xy_tab5_render.restype=c.c_bool
        v.xy_tab5_key.argtypes=[c.c_uint8];v.xy_tab5_touch.argtypes=[c.c_uint32,c.c_uint32]
        v.xy_tab5_state.argtypes=[c.c_uint32];v.xy_tab5_state.restype=c.c_uint32
        cls.entries=[]
        for i in range(struct.unpack_from('<I',cls.data,16)[0]):
            cls.entries.append(struct.unpack_from('<9I',cls.data,64+36*i))
    def setUp(self):
        self.assertTrue(self.vm.xy_tab5_init(self.owner,len(self.data)))
        self.pixels=c.create_string_buffer(720*1280*2+64)
        c.memset(self.pixels,0xa5,len(self.pixels))
    def state(self,n):return self.vm.xy_tab5_state(n)
    def render(self):
        self.assertTrue(self.vm.xy_tab5_render(c.byref(self.pixels,32),720*1280*2),self.state(8))
        self.assertEqual(self.pixels.raw[:32],b'\xa5'*32)
        self.assertEqual(self.pixels.raw[-32:],b'\xa5'*32)
        return hashlib.sha256(self.pixels.raw[32:-32]).hexdigest()
    def key(self,key):self.vm.xy_tab5_key(ord(key) if isinstance(key,str) else key)
    def open(self,book,chapter=0):
        self.key(27);self.key(str(book+1))
        for _ in range(chapter):self.key(129)
        self.key(13);return self.render()
    def test_rom_pack_matches_each_source_section_and_ruby(self):
        source=json.loads((ROOT/'assets/xy/library.json').read_text())
        at=0
        for book,item in enumerate(source['items']):
            for section in item['sections']:
                row=self.entries[at];at+=1
                self.assertEqual(row[0],book)
                self.assertEqual(self.data[row[1]:row[1]+row[2]].decode(),section['title'])
                if book!=0:self.assertEqual(self.data[row[3]:row[3]+row[4]].decode(),section['text'])
                self.assertEqual(row[6],len(section['ruby']))
                for j,r in enumerate(section['ruby']):
                    start,end,p,n=struct.unpack_from('<4I',self.data,row[5]+16*j)
                    self.assertEqual((start,end),(r['start'],r['end']))
                    self.assertEqual(self.data[p:p+n].decode(),r['text'])
        self.assertEqual(at,len(self.entries))
    def test_invalid_rom_is_rejected_without_rendering(self):
        self.assertFalse(self.vm.xy_tab5_init(self.owner,63))
        broken=bytearray(self.data);struct.pack_into('<I',broken,64+4,len(broken)+1)
        bad=c.create_string_buffer(bytes(broken));self.assertFalse(self.vm.xy_tab5_init(bad,len(broken)))
    def test_learning_catalogue_is_embedded_and_matches_source(self):
        from xy_learning_pack import build
        offset,length=struct.unpack_from('<2I',self.data,40)
        self.assertGreater(length,128)
        self.assertEqual(self.data[offset:offset+length],build(ROOT))
        broken=bytearray(self.data);struct.pack_into('<I',broken,44,len(broken))
        bad=c.create_string_buffer(bytes(broken));self.assertFalse(self.vm.xy_tab5_init(bad,len(broken)))
    def test_home_touch_chapter_page_and_settings(self):
        home=self.render()
        self.vm.xy_tab5_touch(200,340);self.assertEqual(self.state(1),1)
        self.assertNotEqual(home,self.render())
        self.vm.xy_tab5_touch(300,150);self.render();self.assertEqual(self.state(0),3)
        end=self.state(4)
        self.vm.xy_tab5_touch(600,680);self.render();self.assertEqual(self.state(3),end)
        self.vm.xy_tab5_touch(1120,680);self.assertEqual(self.state(0),4)
        self.vm.xy_tab5_touch(900,190);self.key('v');self.key(13)
        self.assertEqual(self.state(3),end);self.assertEqual(self.state(6),36)
        self.assertEqual(self.state(7),1);self.render()
    def test_all_chapter_starts_render_in_both_directions(self):
        for axis in range(2):
            if axis:self.key('s');self.key('v');self.key(13)
            for book,count in enumerate((3,13,3,32)):
                for chapter in range(count):
                    with self.subTest(book=book,chapter=chapter,axis=axis):
                        self.open(book,chapter)
                        self.assertGreater(self.state(4),self.state(3))
    def test_full_kusamakura_first_chapter_is_contiguous_and_reflows(self):
        self.open(1);row=next(r for r in self.entries if r[0]==1)
        body=self.data[row[3]:row[3]+row[4]];at=0;chunks=[];pages=0
        while True:
            self.assertEqual(self.state(3),at)
            end=self.state(4);self.assertGreater(end,at)
            chunks.append(body[at:end]);at=end;pages+=1
            if end==len(body):break
            self.key(131);self.render();self.assertLess(pages,500)
        self.assertEqual(b''.join(chunks),body)
        self.key(130);previous=self.state(3);self.key('s');self.key('v');self.key(13);self.render()
        self.assertEqual(self.state(3),previous)
    def test_touch_paginates_contents_beyond_first_eight_chapters(self):
        self.key('4');self.render();self.vm.xy_tab5_touch(600,680)
        self.render();self.vm.xy_tab5_touch(300,150);self.render()
        self.assertEqual(self.state(2),8)
    def test_sideways_sicp_sections_page_without_missing_or_repeated_bytes(self):
        self.key('s');self.key('v');self.key(13)
        sections=[r for r in self.entries if r[0]==2]
        for chapter,row in enumerate(sections):
            self.open(2,chapter)
            body=self.data[row[3]:row[3]+row[4]];at=0;chunks=[];pages=0
            while at<len(body):
                self.assertEqual(self.state(3),at)
                end=self.state(4);self.assertGreater(end,at)
                chunks.append(body[at:end]);at=end;pages+=1
                if at<len(body):self.key(131);self.render()
                self.assertLess(pages,500)
            self.assertEqual(b''.join(chunks),body)
    def test_returning_home_and_book_preserves_current_page(self):
        self.open(1);self.key(131);self.render();at=self.state(3)
        self.key('h');self.render();self.key('r');self.render()
        self.assertEqual(self.state(3),at)
    def test_previous_crosses_back_to_last_page_and_keeps_chapter_history(self):
        self.open(2);length=next(r[4] for r in self.entries if r[0]==2)
        offsets=[self.state(3)]
        while self.state(4)<length:
            self.key(131);self.render();offsets.append(self.state(3))
            self.assertLess(len(offsets),100)
        self.assertGreater(len(offsets),2)
        self.key(131);self.render();self.assertEqual(self.state(2),1)
        self.key(130);self.render()
        self.assertEqual((self.state(2),self.state(3)),(0,offsets[-1]))
        self.key(130);self.render()
        self.assertEqual((self.state(2),self.state(3)),(0,offsets[-2]))

if __name__=='__main__':unittest.main()
