"""POSIX capture adapter: reconnect without changing modem lines or flushing boot bytes.

Normal esptool operations retain the base class behavior. Only a cold-boot
capture open suppresses the calls made by pyserial.Serial.open().
"""
import termios


def disconnected(error):
    """pyserial may wrap a termios/OS errno in a string-only exception."""
    while error is not None:
        code = getattr(error, 'errno', None)
        if code is None and error.args and isinstance(error.args[0], int):
            code = error.args[0]
        if code in (2, 6, 19):
            return True
        error = error.__cause__ or error.__context__
    return False


def disable_hangup(port):
    attributes = termios.tcgetattr(port.fd)
    if attributes[2] & termios.HUPCL:
        attributes[2] &= ~termios.HUPCL
        termios.tcsetattr(port.fd, termios.TCSANOW, attributes)


def capture_serial_class(base, passive_configure=disable_hangup):
    class CaptureSerial(base):
        passive_open = False

        def _reconfigure_port(self, *args, **kwargs):
            super()._reconfigure_port(*args, **kwargs)
            if self.passive_open:
                passive_configure(self)

        def _update_dtr_state(self):
            if not self.passive_open:
                super()._update_dtr_state()

        def _update_rts_state(self):
            if not self.passive_open:
                super()._update_rts_state()

        def _reset_input_buffer(self):
            if not self.passive_open:
                super()._reset_input_buffer()

    return CaptureSerial
