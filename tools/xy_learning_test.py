#!/usr/bin/env python3
"""Real shared-core lesson flow through the Mac ABI and rotated Tab5 renderer."""
import ctypes as c
import hashlib
import json
from pathlib import Path
import sys
import unittest

import xy_reader_test as reader
import xy_tab5_reader_test as device

ROOT = Path(__file__).resolve().parents[1]
ASSET = json.loads((ROOT / 'assets/xy/sicp-learning.json').read_bytes())


@unittest.skipUnless(sys.platform == 'darwin', 'Mac ABI integration')
class MacLearning(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        reader.ReaderTest.setUpClass()
        cls.vm = v = reader.ReaderTest.vm
        cls.mincho = reader.ReaderTest.mincho
        cls.gothic = reader.ReaderTest.gothic
        cls.pack = (ROOT / 'build/xy-mac/learning.pack').read_bytes()
        cls.library = (ROOT / 'assets/xy/library.json').read_bytes()
        v.xy_host_learning_bind.argtypes = [c.c_char_p,c.c_uint32,c.c_char_p,c.c_uint32]
        v.xy_host_learning_bind.restype = c.c_bool
        v.xy_host_learning_page.argtypes = [c.c_uint32,c.c_uint32,c.c_uint32]
        v.xy_host_learning_choice.argtypes = [c.c_uint32,c.c_void_p,c.c_uint32]
        v.xy_host_learning_open.argtypes = [c.c_uint32];v.xy_host_learning_open.restype = c.c_bool
        v.xy_host_learning_insert.argtypes = [c.c_char_p,c.c_uint32,c.c_bool];v.xy_host_learning_insert.restype = c.c_bool
        v.xy_host_learning_action.argtypes = [c.c_uint32]
        v.xy_host_learning_copy.argtypes = [c.c_uint32,c.c_void_p,c.c_uint32]
    eval = reader.ReaderTest.eval
    buffer = reader.ReaderTest.buffer
    page = reader.ReaderTest.page
    def setUp(self):
        reader.ReaderTest.setUp(self)
        self.assertTrue(self.vm.xy_host_learning_bind(self.pack,len(self.pack),self.library,len(self.library)))
        self.assertGreaterEqual(self.eval('(buffer/insert! "original 葛󠄀")'),0)
        self.original = self.buffer()
        self.assertTrue(self.vm.xy_host_reader_enter())
    def open(self, snippet='sicp.expressions.addition'):
        section=next(s for s in ASSET['sections'] if any(b.get('snippet')==snippet and b['kind']=='code' for b in s['blocks']))
        block=next(b for b in section['blocks'] if b.get('snippet')==snippet and b['kind']=='code')
        index=next(i for i,s in enumerate(ASSET['sections']) if s['id']==section['id'])
        body=reader.PACK['items'][2]['sections'][index]
        end=self.page(body,block['start'])
        self.assertGreater(self.vm.xy_host_learning_page(index,block['start'],end),0)
        self.reading_frame=self.frame()
        self.reading_text=self.buffer()
        self.assertTrue(self.vm.xy_host_learning_open(0))
        return index,block['start'],end
    def text(self,field):
        out=c.create_string_buffer(4096)
        n=self.vm.xy_host_learning_copy(field,out,len(out));self.assertGreaterEqual(n,0)
        return out.raw[:n]
    def replace(self,text):
        b=text.encode() if isinstance(text,str) else text
        self.assertTrue(self.vm.xy_host_learning_insert(b,len(b),True))
    def frame(self):
        pixels=c.create_string_buffer(1280*720*4)
        self.assertGreaterEqual(self.vm.xy_host_render_rgba8(pixels,1280,720,1280*4,0),0)
        return hashlib.sha256(pixels.raw).hexdigest()
    def test_edit_run_notes_return_and_original_document_undo(self):
        context=self.open()
        self.assertEqual(self.text(0),b'(+ 137 349)')
        self.replace('(+ 137 350)')
        self.assertEqual(self.vm.xy_host_learning_action(0),0)
        self.assertEqual(self.text(2),b'487')
        self.assertEqual(self.text(5),b'486')
        self.assertNotEqual(self.frame(),self.reading_frame)
        self.assertEqual(self.buffer(),self.reading_text)
        self.vm.xy_host_learning_action(3)
        self.replace('日本語のメモ')
        self.assertEqual(self.text(1),'日本語のメモ'.encode())
        self.assertEqual(self.vm.xy_host_learning_action(0),0) # notes never evaluated
        self.assertEqual(self.text(2),b'487')
        self.vm.xy_host_learning_leave()
        self.assertEqual(self.frame(),self.reading_frame)
        self.assertGreater(self.vm.xy_host_learning_page(*context),0)
        self.assertTrue(self.vm.xy_host_learning_open(0))
        self.assertEqual(self.text(0),b'(+ 137 350)')
        self.assertEqual(self.text(1),'日本語のメモ'.encode())
        self.vm.xy_host_learning_leave();self.vm.xy_host_reader_leave()
        self.assertEqual(self.buffer(),self.original)
        self.assertGreaterEqual(self.eval('(buffer/undo!)'),0)
        self.assertEqual(self.buffer(),b'')
    def test_vm_persistence_rollback_side_effect_rejection_and_error_recovery(self):
        self.open()
        self.replace('(define x 5) x');self.assertEqual(self.vm.xy_host_learning_action(0),0)
        self.replace('(set! x 9) missing');self.assertLess(self.vm.xy_host_learning_action(0),0)
        self.replace('x');self.assertEqual(self.vm.xy_host_learning_action(0),0)
        self.assertEqual(self.text(2),b'5')
        self.replace('(buffer/insert! "bad")');self.assertLess(self.vm.xy_host_learning_action(0),0)
        self.assertEqual(self.buffer(),self.reading_text)
        self.replace('(camera/capture!)');self.assertLess(self.vm.xy_host_learning_action(0),0)
        self.replace('(define (loop) (loop)) (loop)');self.assertLess(self.vm.xy_host_learning_action(0),0)
        self.replace('(+ 1 2)');self.assertEqual(self.vm.xy_host_learning_action(0),0)
        self.assertEqual(self.text(2),b'3')
        self.vm.xy_host_learning_action(1)
        self.replace('x');self.assertLess(self.vm.xy_host_learning_action(0),0)
    def test_switching_lessons_keeps_drafts_but_starts_a_fresh_vm(self):
        self.open(); self.replace('(define marker 7) marker')
        self.assertEqual(self.vm.xy_host_learning_action(0),0)
        self.vm.xy_host_learning_leave()
        other=next(e['editable'] for e in ASSET['experiments'] if e['features']==['integer'] and e['editable']!='sicp.expressions.addition')
        self.open(other); self.replace('marker')
        self.assertLess(self.vm.xy_host_learning_action(0),0)
        self.vm.xy_host_learning_leave(); self.open()
        self.assertEqual(self.text(4),b'')
        self.assertEqual(self.text(0),b'(define marker 7) marker')
        self.replace('marker')
        self.assertLess(self.vm.xy_host_learning_action(0),0)

    def test_original_code_restore_is_undoable_and_invalid_edits_preserve_draft(self):
        self.open();self.replace('(+ 1 2)')
        self.assertFalse(self.vm.xy_host_learning_insert(b'\xff',1,True))
        self.assertEqual(self.text(0),b'(+ 1 2)')
        self.assertFalse(self.vm.xy_host_learning_insert(b'x'*4097,4097,True))
        self.assertEqual(self.text(0),b'(+ 1 2)')
        self.vm.xy_host_learning_action(2);self.assertEqual(self.text(0),b'(+ 137 349)')
        self.vm.xy_host_learning_action(4);self.assertEqual(self.text(0),b'(+ 1 2)')
    def test_unsupported_example_and_wrong_library_are_explicit(self):
        self.assertFalse(self.vm.xy_host_learning_bind(self.pack,len(self.pack),b'wrong',5))
        self.open('sicp.expressions.division')
        self.assertLess(self.vm.xy_host_learning_action(0),0)
        self.assertEqual(self.text(4),b'Unsupported')
    def test_all_nine_integer_source_examples_execute_in_isolated_contexts(self):
        seen=0
        for e in ASSET['experiments']:
            if e['features']!=['integer']:continue
            self.open(e['editable'])
            self.assertEqual(self.vm.xy_host_learning_action(0),0,e['id'])
            if e['reference']:self.assertEqual(self.text(2).decode(),e['reference']['text'])
            self.vm.xy_host_learning_leave();seen+=1
        self.assertEqual(seen,9)


class Tab5Learning(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        device.DeviceReader.setUpClass();cls.vm=device.DeviceReader.vm
        cls.owner=device.DeviceReader.owner;cls.data=device.DeviceReader.data
        v=cls.vm
        v.xy_tab5_learning_replace.argtypes=[c.c_char_p,c.c_uint32];v.xy_tab5_learning_replace.restype=c.c_bool
        v.xy_tab5_learning_copy.argtypes=[c.c_uint32,c.c_void_p,c.c_uint32]
    state=device.DeviceReader.state
    render=device.DeviceReader.render
    key=device.DeviceReader.key
    open=device.DeviceReader.open
    def setUp(self):device.DeviceReader.setUp(self)
    def text(self,field):
        out=c.create_string_buffer(4096);n=self.vm.xy_tab5_learning_copy(field,out,len(out))
        self.assertGreaterEqual(n,0);return out.raw[:n]
    def test_actual_touch_key_edit_run_notes_and_same_page_return(self):
        self.open(2,1)
        section=ASSET['sections'][1]
        anchor=next(b for b in section['blocks'] if b.get('snippet')=='sicp.expressions.addition' and b['kind']=='code')
        while self.state(4)<=anchor['start']:self.key(131);self.render()
        start,end=self.state(3),self.state(4)
        before=self.render()
        choices=[b for b in section['blocks'] if b['kind']=='code' and b['start']<end and b['end']>start]
        ordinal=next(i for i,b in enumerate(choices) if b['snippet']=='sicp.expressions.addition')
        self.vm.xy_tab5_touch(720,680);self.assertEqual(self.state(0),6);self.render()
        for _ in range(ordinal):self.key(129)
        self.key(13);self.assertEqual(self.state(0),7);self.render()
        changed=b'(+ 137 350)';self.assertTrue(self.vm.xy_tab5_learning_replace(changed,len(changed)))
        self.key(12);self.render();self.assertEqual(self.text(2),b'487')
        self.key('x');self.key(8);self.assertEqual(self.text(0),changed)
        self.vm.xy_tab5_touch(300,680);self.render();self.assertEqual(self.text(2),b'487')
        self.vm.xy_tab5_touch(1100,680)
        note='日本語のメモ'.encode();self.assertTrue(self.vm.xy_tab5_learning_replace(note,len(note)));self.render()
        self.assertEqual(self.text(1),note)
        self.key(27);self.assertEqual(self.state(0),3)
        self.assertEqual((self.state(3),self.state(4)),(start,end));self.assertEqual(self.render(),before)
        self.key('e')
        self.key(13);self.assertEqual(self.text(0),changed);self.assertEqual(self.text(1),note)


if __name__ == '__main__':unittest.main()
