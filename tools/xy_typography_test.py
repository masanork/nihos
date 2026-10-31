#!/usr/bin/env python3
"""Attributed SICP font roles through the actual Mac and Tab5 renderers."""
import ctypes as c
import hashlib
import json
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET
import xy_learning_test as learn
import xy_reader_test as reader
import xy_tab5_reader_test as device
import xy_sicp
ROOT=Path(__file__).resolve().parents[1]
ASSET=json.loads((ROOT/'assets/xy/sicp-learning.json').read_bytes())
class Glyph(c.Structure):
    _fields_=[('cp',c.c_uint32),('ivs',c.c_uint32),('offset',c.c_uint32),('run',c.c_uint8),('style',c.c_uint8),('size',c.c_uint8),('vertical',c.c_uint8),('x',c.c_int32),('y',c.c_int32),('ink_x',c.c_int32),('ink_y',c.c_int32),('width',c.c_uint16),('height',c.c_uint16),('advance',c.c_uint16)]
def glyphs(fn):
    out=[]
    for i in range(2048):
        g=Glyph()
        if not fn(i,c.byref(g)): return out
        out.append(g)
    raise AssertionError('Unbounded glyph result')

class SourceTypography(unittest.TestCase):
    def test_inline_code_is_attributed_without_changing_prose_or_becoming_an_experiment(self):
        root=ET.fromstring('<SECTION><TEXT>日本語 <SCHEMEINLINE>fact-iter</SCHEMEINLINE> is a procedure.</TEXT></SECTION>')
        text,blocks=xy_sicp.render(root,{})
        self.assertEqual(text,'日本語 fact-iter is a procedure.\n')
        self.assertEqual([b['kind'] for b in blocks],['inline_code'])
        b=blocks[0];self.assertEqual(text.encode()[b['start']:b['end']],b'fact-iter')
    def test_derived_font_is_bound_to_its_pinned_source_and_manifest(self):
        manifest=json.loads((ROOT/'src/graphics/serif/manifest.json').read_bytes())
        for path,key in [('third_party/xy-typography/texgyreschola-regular.otf','source_sha256'),('src/graphics/serif/nihos-book-serif.ttf','output_sha256')]:
            self.assertEqual(hashlib.sha256((ROOT/path).read_bytes()).hexdigest(),manifest[key])

@unittest.skipUnless(sys.platform=='darwin','Mac ABI')
class MacTypography(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        learn.MacLearning.setUpClass()
        for name in ('vm','mincho','gothic','pack','library'):setattr(cls,name,getattr(learn.MacLearning,name))
        v=cls.vm
        v.xy_host_reader_context.argtypes=[c.c_uint32,c.c_uint32,c.c_uint32];v.xy_host_reader_context.restype=c.c_bool
        v.xy_host_reader_glyph.argtypes=[c.c_uint32,c.POINTER(Glyph)];v.xy_host_reader_glyph.restype=c.c_bool
    eval=reader.ReaderTest.eval
    buffer=reader.ReaderTest.buffer
    page=reader.ReaderTest.page
    frame=learn.MacLearning.frame
    def setUp(self):learn.MacLearning.setUp(self)
    def test_mixed_page_uses_serif_prose_monospace_code_and_preserves_original_document(self):
        section=ASSET['sections'][1];body=reader.PACK['items'][2]['sections'][1]
        anchor=next(b for b in section['blocks'] if b.get('snippet')=='sicp.expressions.addition' and b['kind']=='code')
        start=anchor['start']-140
        self.assertTrue(self.vm.xy_host_reader_context(2,1,start));end=self.page(body,start);self.frame()
        gs=glyphs(self.vm.xy_host_reader_glyph);styles={g.style for g in gs if g.cp}
        self.assertTrue({2,3}<=styles)
        source=[b for b in section['blocks'] if b['kind'] in ('code','reference_output','inline_code','math')]
        for g in gs:
            if not g.cp or g.run:continue
            expected=3 if any(b['start']<=start+g.offset<b['end'] for b in source) else 2
            self.assertEqual(g.style,expected,(chr(g.cp),start+g.offset))
        mono={g.advance for g in gs if g.style==3 and 33<=g.cp<127}
        prose={g.advance for g in gs if g.style==2 and 33<=g.cp<127}
        self.assertEqual(len(mono),1);self.assertGreater(len(prose),3)
        self.assertTrue(self.vm.xy_host_reader_context(2,1,start));self.assertGreater(self.vm.xy_host_learning_page(1,start,end),0)
        self.assertTrue(self.vm.xy_host_learning_open(0));self.frame()
        self.assertEqual({g.style for g in glyphs(self.vm.xy_host_reader_glyph) if g.cp},{0})
        self.vm.xy_host_learning_leave();self.vm.xy_host_reader_leave();self.assertEqual(self.buffer(),self.original)
    def test_prose_fits_more_source_text_at_the_same_size(self):
        body=reader.PACK['items'][2]['sections'][0]
        self.assertGreaterEqual(self.eval("(view/set! #:size 36 #:direction 'horizontal #:line-gap 18)"),0)
        before=self.page(body,0)
        self.assertTrue(self.vm.xy_host_reader_context(2,0,0));after=self.page(body,0)
        self.assertGreater(after,before)
        stable=self.frame()
        self.assertFalse(self.vm.xy_host_reader_context(2,99,0))
        self.assertEqual(self.frame(),stable)
        self.assertTrue(self.vm.xy_host_reader_context(0,0,0))
        self.assertLess(self.vm.xy_host_reader_load(b'\xff',1,b'',0,None,0),0)
        self.assertEqual(self.frame(),stable)

class Tab5Typography(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        device.DeviceReader.setUpClass();cls.vm=device.DeviceReader.vm;cls.owner=device.DeviceReader.owner;cls.data=device.DeviceReader.data
        cls.vm.xy_tab5_glyph.argtypes=[c.c_uint32,c.POINTER(Glyph)];cls.vm.xy_tab5_glyph.restype=c.c_bool
    setUp=device.DeviceReader.setUp
    key=device.DeviceReader.key
    state=device.DeviceReader.state
    open=device.DeviceReader.open
    render=device.DeviceReader.render
    def test_native_page_fitting_and_painting_use_the_same_prose_and_code_roles(self):
        self.open(2,1)
        seen=set()
        for _ in range(40):
            gs=glyphs(self.vm.xy_tab5_glyph);seen|={g.style for g in gs if g.cp}
            if {2,3}<=seen:break
            self.key(131);self.render()
        self.assertTrue({2,3}<=seen)
        for _ in range(2):
            self.key('s');self.key('f');self.key(13);self.render()
            self.assertTrue(any(g.style in (2,4) for g in glyphs(self.vm.xy_tab5_glyph) if g.cp))
if __name__=='__main__':unittest.main()
