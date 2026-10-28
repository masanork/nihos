"""Use a private PTY to verify kernel exclusion; never open a physical device."""
import fcntl
import os
import pty
import termios
import unittest
from types import SimpleNamespace
import native_serial as SERIAL


class KernelSerialExclusiveTests(unittest.TestCase):
    def test_real_pty_can_never_false_claim_exclusion(self):
        master, slave = pty.openpty()
        try:
            path = os.ttyname(slave)
            try:
                SERIAL.claim_kernel_exclusive(SimpleNamespace(fd=slave, port=path))
            except RuntimeError as error:
                self.assertIn('not enforced', str(error))
                reopened = os.open(path, os.O_RDWR | os.O_NOCTTY)
                os.close(reopened)
            else:
                with self.assertRaises(OSError): os.open(path, os.O_RDWR | os.O_NOCTTY)
                fcntl.ioctl(slave, termios.TIOCNXCL)
        finally:
            os.close(slave)
            os.close(master)

    def test_both_serial_aliases_must_deny_raw_second_open(self):
        import errno
        from unittest.mock import patch
        port = SimpleNamespace(fd=99, port='/dev/cu.test')
        busy = OSError(errno.EBUSY, 'busy')
        with patch.object(SERIAL.fcntl, 'ioctl') as ioctl, patch.object(SERIAL.os, 'open', side_effect=[busy,busy]) as opener:
            SERIAL.claim_kernel_exclusive(port)
            self.assertEqual(opener.call_count,2)
            ioctl.assert_called_once_with(99,termios.TIOCEXCL)
        with patch.object(SERIAL.fcntl, 'ioctl') as ioctl, patch.object(SERIAL.os, 'open', side_effect=[busy,123]), patch.object(SERIAL.os, 'close') as closer:
            with self.assertRaisesRegex(RuntimeError,'not enforced'): SERIAL.claim_kernel_exclusive(port)
            closer.assert_called_once_with(123)
            self.assertEqual(ioctl.call_args_list[-1].args,(99,termios.TIOCNXCL))

    def test_claim_precedes_modem_lines_and_passive_open_stays_passive(self):
        events = []
        class Base:
            exclusive = True
            def _reconfigure_port(self, **kwargs): events.append('configure')
            def _update_dtr_state(self): events.append('dtr')
            def _update_rts_state(self): events.append('rts')
            def _reset_input_buffer(self): events.append('flush')
            def open(self):
                self._reconfigure_port(force_update=True)
                self._update_dtr_state(); self._update_rts_state(); self._reset_input_buffer()
        Port = SERIAL.capture_serial_class(Base, lambda _: events.append('hupcl'), lambda _: events.append('kernel-claim'))
        port = Port(); port.open()
        self.assertEqual(events, ['configure','kernel-claim','dtr','rts','flush'])
        events.clear();port.passive_open=True;port.open()
        self.assertEqual(events, ['configure','kernel-claim','hupcl'])

    def test_claim_failure_prevents_modem_line_changes(self):
        events = []
        class Base:
            exclusive = True
            def _reconfigure_port(self): events.append('configure')
            def _update_dtr_state(self): events.append('dtr')
            def open(self): self._reconfigure_port(); self._update_dtr_state()
        def reject(_): raise OSError('busy')
        Port = SERIAL.capture_serial_class(Base, exclusive_configure=reject)
        with self.assertRaises(OSError): Port().open()
        self.assertEqual(events, ['configure'])


if __name__ == '__main__': unittest.main()
