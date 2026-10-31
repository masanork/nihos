import unittest
from xy_camera import reply_bytes, jpeg_chunk, reconstruct, fnv


class CameraReplyTests(unittest.TestCase):
    def test_scheme_bytes_are_exact_and_bounded(self):
        self.assertEqual(jpeg_chunk(reply_bytes(b'NIHOS_NATIVE_XY_REPLY data=226666643822'),2),b'\xff\xd8')
        self.assertEqual(jpeg_chunk(b'""',0),b'')
        for data,count in [(b'"ffd8"',1),(b'"ffd"',2),(b'"FFd8"',2),(b'ffd8',2),(b'""',33),(b'""',-1)]:
            with self.assertRaises(ValueError):jpeg_chunk(data,count)

    def test_trace_reply_cannot_expand_or_truncate_a_scheme_result(self):
        for value in [b'NIHOS_NATIVE_XY_REPLY data=0',b'NIHOS_NATIVE_XY_REPLY data=GG',b'NIHOS_NATIVE_XY_REPLY data='+b'00'*129,b'prefix NIHOS_NATIVE_XY_REPLY data=00']:
            with self.assertRaises(ValueError):reply_bytes(value)

    def test_reconstruct_deduplicates_state_echoes_and_rejects_corruption(self):
        payload=b'\xff\xd8'+bytes(range(256))*3+b'\xff\xd9'
        lines=[f'NIHOS_XY_JPEG_READY handle=00000001 bytes={len(payload):08x} width=00000500 height=000002d0 source_fnv=12345678 encode_us=00004aa6 fnv={fnv(payload):08x}'.encode()]
        def reply(revision,value):
            lines.extend([f'NIHOS_NATIVE_XY_STATE revision={revision:08x}'.encode(),b'NIHOS_NATIVE_XY_REPLY data='+value.hex().encode()])
        reply(1,f'(ready 1280 720 {len(payload)})'.encode())
        reply(1,f'(ready 1280 720 {len(payload)})'.encode())
        for index,start in enumerate(range(0,len(payload),32),2):
            value=b'"'+payload[start:start+32].hex().encode()+b'"'
            reply(index,value);reply(index,value)
        text=b'\n'.join(lines)
        self.assertEqual(reconstruct(text)[1],payload)
        for changed in [text.replace(b'66666438',b'66666439',1),b'\n'.join(lines[:-4]),text.replace(b'width=00000500',b'width=00000501'),text.replace(b'encode_us=00004aa6',b'encode_us=00000000'),text.replace(b'revision=00000001',b'revision=00000001 tx_dropped=00000001',1),text+b'\n'+lines[0]]:
            self.assertNotEqual(changed,text)
            with self.assertRaises(ValueError):reconstruct(changed)
