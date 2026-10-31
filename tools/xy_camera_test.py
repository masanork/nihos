import unittest
from xy_camera import reply_bytes, jpeg_chunk


class CameraReplyTests(unittest.TestCase):
    def test_scheme_bytes_are_exact_and_bounded(self):
        self.assertEqual(jpeg_chunk(reply_bytes(b'NIHOS_NATIVE_XY_REPLY data=226666643822'),2),b'\xff\xd8')
        self.assertEqual(jpeg_chunk(b'""',0),b'')
        for data,count in [(b'"ffd8"',1),(b'"ffd"',2),(b'"FFd8"',2),(b'ffd8',2),(b'""',33),(b'""',-1)]:
            with self.assertRaises(ValueError):jpeg_chunk(data,count)

    def test_trace_reply_cannot_expand_or_truncate_a_scheme_result(self):
        for value in [b'NIHOS_NATIVE_XY_REPLY data=0',b'NIHOS_NATIVE_XY_REPLY data=GG',b'NIHOS_NATIVE_XY_REPLY data='+b'00'*129,b'prefix NIHOS_NATIVE_XY_REPLY data=00']:
            with self.assertRaises(ValueError):reply_bytes(value)
