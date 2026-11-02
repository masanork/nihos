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

class TerminalCell(c.Structure):
    _fields_=[('codepoint',c.c_uint32),('fg',c.c_uint16),('bg',c.c_uint16),('flags',c.c_uint8)]

class TerminalView(c.Structure):
    _fields_=[('cols',c.c_uint16),('rows',c.c_uint16),('cursor_col',c.c_uint16),('cursor_row',c.c_uint16),('cursor_visible',c.c_bool),('cells',c.POINTER(TerminalCell))]

class DeviceReader(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data=(OUT/'xy-reading.pack').read_bytes()
        cls.owner=c.create_string_buffer(cls.data)
        cls.vm=v=c.CDLL(str(OUT/('libxy_tab5.dylib' if sys.platform=='darwin' else 'libxy_tab5.so')))
        v.xy_tab5_init.argtypes=[c.c_void_p,c.c_uint32];v.xy_tab5_init.restype=c.c_bool
        v.xy_tab5_render.argtypes=[c.c_void_p,c.c_uint32];v.xy_tab5_render.restype=c.c_bool
        v.xy_tab5_render_terminal.argtypes=[c.c_void_p,c.c_uint32,c.POINTER(TerminalView)];v.xy_tab5_render_terminal.restype=c.c_bool
        v.xy_tab5_key.argtypes=[c.c_uint8];v.xy_tab5_touch.argtypes=[c.c_uint32,c.c_uint32]
        v.xy_tab5_set_portrait.argtypes=[c.c_bool]
        v.xy_tab5_set_portrait_keyboard.argtypes=[c.c_bool]
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
        if chapter > 0:
            self.key('c')
            for _ in range(chapter):self.key(129)
            self.key(13)
        return self.render()
    def test_terminal_preview_preserves_bounds_and_orientation(self):
        cells=(TerminalCell*(80*24))()
        for cell in cells: cell.codepoint=32;cell.fg=0xffff;cell.bg=0
        cells[0]=TerminalCell(32,0x07e0,0xf800,0)
        cells[1]=TerminalCell(ord('A'),0xffff,0x001f,0)
        view=TerminalView(80,24,0,0,True,cells)
        for portrait in (True,False):
            self.vm.xy_tab5_set_portrait(portrait)
            self.assertTrue(self.vm.xy_tab5_render_terminal(c.byref(self.pixels,32),720*1280*2,c.byref(view)))
            self.assertEqual(self.pixels.raw[:32],b'\xa5'*32)
            self.assertEqual(self.pixels.raw[-32:],b'\xa5'*32)
            x,y=(4,10) if portrait else (10,1279-4)
            self.assertEqual(struct.unpack_from('<H',self.pixels,32+(y*720+x)*2)[0],0xf800)
        view.cols=81
        self.assertFalse(self.vm.xy_tab5_render_terminal(c.byref(self.pixels,32),720*1280*2,c.byref(view)))

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
        self.assertEqual(self.state(0),3)
        end=self.state(4)
        self.vm.xy_tab5_touch(600,680);self.render();self.assertEqual(self.state(3),end)
        self.vm.xy_tab5_touch(1120,680);self.assertEqual(self.state(0),4)
        self.vm.xy_tab5_touch(900,190);self.key('v');self.key(13)
        self.assertEqual(self.state(3),end);self.assertEqual(self.state(6),36)
        self.assertEqual(self.state(7),1);self.render()
    def test_certification_screen_keyboard_and_touch_in_both_orientations(self):
        for portrait in (False, True):
            with self.subTest(portrait=portrait):
                self.assertTrue(self.vm.xy_tab5_init(self.owner,len(self.data)))
                self.vm.xy_tab5_set_portrait(portrait)
                self.key(27);self.key('s')
                settings=self.render()
                self.vm.xy_tab5_touch(100,110)
                self.assertEqual(self.state(0),9)
                self.assertNotEqual(settings,self.render())
                self.key(13);self.assertEqual(self.state(0),4)
                self.key('g');self.assertEqual(self.state(0),9)
                self.key(27);self.assertEqual(self.state(0),4)

    def test_portrait_home_reader_settings_and_contents_touch(self):
        self.vm.xy_tab5_set_portrait(True)
        home=self.render()
        self.vm.xy_tab5_touch(100,170+2*156+20)
        self.assertEqual((self.state(0),self.state(1)),(3,1))
        self.assertNotEqual(home,self.render())
        end=self.state(4)
        self.vm.xy_tab5_touch(250,1240);self.render()
        self.assertEqual(self.state(3),end)
        self.vm.xy_tab5_touch(620,1240);self.assertEqual(self.state(0),4)
        self.render();self.vm.xy_tab5_touch(500,190)
        self.vm.xy_tab5_touch(100,280);self.vm.xy_tab5_touch(100,590)
        self.assertEqual((self.state(6),self.state(7)),(36,1))
        self.assertEqual(self.state(3),end);self.render()
        self.vm.xy_tab5_touch(500,1240);self.assertEqual(self.state(0),2)
        self.render();self.vm.xy_tab5_touch(100,132+110+5)
        self.assertEqual((self.state(0),self.state(2)),(3,1));self.render()

    def test_portrait_first_chapter_pages_are_contiguous_in_both_axes(self):
        row=next(r for r in self.entries if r[0]==1)
        body=self.data[row[3]:row[3]+row[4]]
        rubies=[struct.unpack_from('<4I',self.data,row[5]+16*j) for j in range(row[6])]
        for axis in range(2):
            self.assertTrue(self.vm.xy_tab5_init(self.owner,len(self.data)))
            self.vm.xy_tab5_set_portrait(True)
            if axis:
                self.key('s');self.key('v');self.key(13)
            self.key('2');self.render()
            at=0;pages=0;chunks=[]
            while True:
                self.assertEqual(self.state(3),at)
                end=self.state(4);self.assertGreater(end,at)
                body[at:end].decode()
                self.assertTrue(all(r[1] <= end for r in rubies if at <= r[0] < end))
                chunks.append(body[at:end]);at=end;pages+=1
                if end==len(body):break
                self.vm.xy_tab5_touch(250,1240);self.render();self.assertLess(pages,500)
            self.assertEqual(b''.join(chunks),body)

    def test_portrait_sicp_try_and_lesson_controls(self):
        self.vm.xy_tab5_set_portrait(True)
        self.key('3');self.key('c');self.key(129);self.key(13);self.render()
        for _ in range(30):
            if self.state(10): break
            if self.state(4) >= self.state(9): self.fail('SICP example not found')
            self.key(131);self.render()
        self.assertTrue(self.state(10))
        self.vm.xy_tab5_touch(370,1240);self.assertEqual(self.state(0),6);self.render()
        self.vm.xy_tab5_touch(40,140);self.assertEqual(self.state(0),7);self.render()
        self.key('x');without_keyboard=self.render()
        self.vm.xy_tab5_set_portrait_keyboard(True);self.assertNotEqual(without_keyboard,self.render())
        self.vm.xy_tab5_touch(650,910);self.render()  # notes, above dock
        self.key('y');self.render()
        self.vm.xy_tab5_touch(40,910);self.assertEqual(self.state(0),3);self.render()

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
    def test_pages_fill_the_available_cells_at_every_font_size_and_axis(self):
        # A long, unbroken paragraph exercises both the old 400-cluster cap
        # and BlockFull's 25% backoff. Independently compute the cell capacity,
        # including the status row, ruby band, margins and line spacing.
        row_index=next(i for i,r in enumerate(self.entries) if r[0]==1)
        for char in ('山','a'):
            data=bytearray(self.data);text=(char*4096).encode();start=len(data)
            data.extend(text)
            struct.pack_into('<I',data,12,len(data))
            struct.pack_into('<4I',data,64+36*row_index+12,start,len(text),0,0)
            owner=c.create_string_buffer(bytes(data))
            for axis in range(2):
                for size in range(16,65,4):
                    with self.subTest(char=char,axis=axis,size=size):
                        self.assertTrue(self.vm.xy_tab5_init(owner,len(data)))
                        self.key('s')
                        for _ in range(abs(size-32)//4):self.key('+' if size>32 else '-')
                        if axis:self.key('v')
                        self.key(13);self.open(1)
                        ruby=size//2;step=size+ruby+12;height=648-size-8
                        # Source Code Pro advances by 0.6 em. Preserve 26.6
                        # precision until division, as the line flow does.
                        advance=size*64 if char=='山' else (size*3*64+2)//5
                        if axis:
                            lines=(1280-48-ruby-size)//step+1
                            cells=(height-48)*64//advance
                        else:
                            lines=(height-48-ruby-size)//step+1
                            cells=(1280-48)*64//advance
                        expected=lines*cells*len(char.encode())
                        self.assertEqual(self.state(4),expected)
                        # Next begins at exactly the first unpainted cell.
                        self.key(131);self.render();self.assertEqual(self.state(3),expected)
                        self.assertEqual(self.state(4),2*expected)
    def test_smallest_kusamakura_pages_keep_all_thirteen_chapters_and_ruby(self):
        rows=[r for r in self.entries if r[0]==1]
        for axis in range(2):
            if axis:self.key('h')
            self.key('s')
            for _ in range(4 if axis==0 else 0):self.key('-')
            if axis:self.key('v')
            self.key(13)
            for chapter,row in enumerate(rows):
                with self.subTest(axis=axis,chapter=chapter):
                    self.open(1,chapter)
                    body=self.data[row[3]:row[3]+row[4]]
                    rubies=[struct.unpack_from('<4I',self.data,row[5]+16*j) for j in range(row[6])]
                    at=0;pages=0
                    while True:
                        self.assertEqual(self.state(3),at)
                        end=self.state(4);self.assertGreater(end,at)
                        body[at:end].decode() # Every page closes at a UTF-8 boundary.
                        spans=[r for r in rubies if at<=r[0]<end]
                        self.assertTrue(all(r[1]<=end for r in spans))
                        self.assertLess(len(spans),128) # Page end must precede the buffer limit.
                        if chapter==0 and pages==0:
                            self.assertEqual(len(body[:end].decode()),(957,1041)[axis])
                            self.assertGreater(len(spans),64)
                        at=end;pages+=1
                        if at==len(body):break
                        self.key(131);self.render();self.assertLess(pages,500)
    def test_touch_paginates_contents_beyond_first_eight_chapters(self):
        self.key('4');self.render();self.key('c');self.render();self.vm.xy_tab5_touch(600,680)
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
    def test_book_opens_directly_to_reading_and_shows_contents_only_when_requested(self):
        self.key(27); self.render() # back to home
        self.assertEqual(self.state(0), 1) # home
        self.key('2'); self.render() # open Kusamakura
        self.assertEqual(self.state(0), 3) # directly in reading, not chapters
        self.assertEqual(self.state(1), 1) # book 1
        self.assertEqual(self.state(2), 0) # chapter 0
        self.assertEqual(self.state(3), 0) # offset 0
        # Request table of contents explicitly via key 'c'
        self.key('c'); self.render()
        self.assertEqual(self.state(0), 2) # chapters
        self.key(27); self.render() # Esc returns to home
        self.assertEqual(self.state(0), 1)
        # Touch opens directly to reading as well
        self.vm.xy_tab5_touch(200, 340); self.render()
        self.assertEqual(self.state(0), 3) # reading
        # Touch table of contents button (x=880, y=680)
        self.vm.xy_tab5_touch(880, 680); self.render()
        self.assertEqual(self.state(0), 2) # chapters
    def test_try_button_shown_only_for_sicp_pages_with_code(self):
        # Kusamakura (book 1): can_try must always be 0
        self.open(1)
        self.assertEqual(self.state(10), 0)
        self.key(131); self.render()
        self.assertEqual(self.state(10), 0)
        self.key('e'); self.render()
        self.assertEqual(self.state(0), 3) # cannot enter examples when can_try is false
        # SICP (book 2): section 1 (Expressions) has code examples
        self.open(2, 1) # chapter 1 (Expressions)
        has_code_page = False
        no_code_page = False
        length = next(r[4] for r in self.entries if r[0] == 2 and r[1] == 1 or True)
        for _ in range(30):
            can_try = self.state(10)
            if can_try == 1:
                has_code_page = True
                # Press 'e' on code page opens examples
                self.key('e'); self.render()
                self.assertEqual(self.state(0), 6) # examples screen
                self.key(27); self.render() # back to home/reading
                break
            else:
                no_code_page = True
            if self.state(4) >= self.state(9): break
            self.key(131); self.render()
        self.assertTrue(has_code_page)


if __name__=='__main__':unittest.main()
