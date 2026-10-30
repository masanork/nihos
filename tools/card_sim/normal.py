"""Production normal-UI models/renderers; host frame publication, no device DMA."""
import ctypes as C
if __package__:
    from .backend import build, digest, FRAME_BYTES, LOCK
else:
    from backend import build, digest, FRAME_BYTES, LOCK

TRACE_LIMIT = 4096
CONTROLLERS = {'direct': (0, 10), 'gt911': (1, 5), 'st7123': (2, 10), 'st7121': (3, 10)}


class ControllerView(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ('status', 'polls', 'fresh', 'errors', 'error_code',
        'transfers', 'report_reads', 'report_bytes', 'max_read', 'acknowledgments', 'fault')]


class View(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ('details', 'accepted', 'down', 'move', 'up',
        'cancel', 'overflow', 'queued', 'last_x', 'last_y', 'failed', 'log_lines', 'mismatches')]


class NormalSimulator:
    def __init__(self, directory=None):
        render, _, self.identity, self.witness = build(directory)
        self.zig = C.CDLL(str(render))
        self.zig.normal_reset.argtypes, self.zig.normal_reset.restype = [C.c_uint32], C.c_bool
        self.zig.normal_view.argtypes = [C.POINTER(View)]
        self.zig.normal_controller_view.argtypes = [C.POINTER(ControllerView)]
        self.zig.normal_controller_reset.argtypes, self.zig.normal_controller_reset.restype = [C.c_uint32, C.c_uint8], C.c_bool
        self.zig.normal_controller_fault.argtypes, self.zig.normal_controller_fault.restype = [C.c_uint32], C.c_bool
        self.zig.normal_controller_report.argtypes = [C.c_uint8, C.c_uint16, C.c_uint16, C.c_bool, C.c_uint64, C.c_bool]
        self.zig.normal_controller_report.restype = C.c_bool
        self.zig.normal_touch.argtypes = [C.c_uint8, C.c_uint16, C.c_uint16, C.c_uint64, C.c_bool]
        self.zig.normal_touch.restype = C.c_bool
        self.zig.normal_tick.argtypes, self.zig.normal_tick.restype = [C.c_uint64, C.c_bool], C.c_bool
        self.zig.normal_drain.restype = C.c_bool
        self.zig.normal_corrupt.restype = C.c_bool
        self.zig.normal_action.argtypes, self.zig.normal_action.restype = [C.c_uint32, C.c_uint32], C.c_bool
        self.zig.normal_render.argtypes = [C.POINTER(C.c_uint8), C.c_size_t]
        self.zig.normal_render.restype = C.c_bool
        self.buffer = (C.c_uint8 * FRAME_BYTES)()
        self.reset()

    @staticmethod
    def integer(value, low, high):
        if type(value) is not int or not low <= value <= high:
            raise ValueError('invalid normal-UI sample')
        return value

    def view(self):
        out = View()
        self.zig.normal_view(C.byref(out))
        return {name: getattr(out, name) for name, _ in View._fields_}

    def pixels(self):
        return self.front

    def state(self):
        view = self.view()
        controller = ControllerView()
        self.zig.normal_controller_view(C.byref(controller))
        return {'application': 'normal', 'view': {**view, 'phase': 'logs' if view['details'] else 'splash'},
                'displayed_phase': self.active_phase, 'status': self.status, 'palette': self.palette,
                'time_us': self.now, 'pixel_sha256': self.front_sha, 'source_identity': self.identity,
                'trace_full': len(self.trace) >= TRACE_LIMIT,
                'controller': {'name': self.controller, 'slots': self.slots,
                               **{name: getattr(controller, name) for name, _ in ControllerView._fields_}},
                'metrics': {'frames': self.frames, 'publications': self.publications, 'pending': int(self.pending),
                            'mismatches': view['mismatches']},
                'scope': 'production UI and foreground touch service/controller driver; synthetic register bus and frame boundary; no physical I2C, IRQ, DMA or timing qualification'}

    def reset(self, palette=4, controller='direct', slots=None):
        with LOCK:
            self.integer(palette, 0, 4)
            if not isinstance(controller, str) or controller not in CONTROLLERS:
                raise ValueError('unknown touch controller')
            panel, default_slots = CONTROLLERS[controller]
            slots = default_slots if slots is None else self.integer(slots, 1, 10)
            if (controller == 'gt911' and slots != 5) or (controller == 'direct' and slots != 10):
                raise ValueError('invalid touch slot count')
            if not self.zig.normal_reset(palette) or not self.zig.normal_controller_reset(panel, slots):
                raise RuntimeError('normal UI reset failed')
            self.palette = palette
            self.controller, self.slots = controller, slots
            self.now = 0 if controller == 'direct' else 1000000
            self.frames = self.publications = 0
            self.front = bytes(FRAME_BYTES)
            self.front_sha = digest(self.front)
            self.active_phase = None
            self.pending = False
            self.status = 0
            self.trace = [{'action': 'reset', 'application': 'normal', 'palette': palette}]
            if controller != 'direct':
                self.trace[0].update(controller=controller, slots=slots)
            self._present(True)
            return self.state()

    def _present(self, automatic):
        if not self.zig.normal_render(self.buffer, FRAME_BYTES):
            self.status = -6
            return
        self.candidate = bytes(self.buffer)
        self.pending = True
        self.status = -5 if self.view()['mismatches'] else 1
        if automatic and self.status >= 0:
            self.eof()

    def eof(self):
        self.frames += 1
        if self.pending and not self.view()['mismatches']:
            self.front = self.candidate
            self.front_sha = digest(self.front)
            self.active_phase = 'logs' if self.view()['details'] else 'splash'
            self.publications += 1
            self.pending = False
            self.status = 0
        return self.state()

    def touch(self, contacts, x, y, automatic=True, dt_us=None, dispatch=True, sparse=False):
        with LOCK:
            self.integer(contacts, 0, 5 if self.controller == 'direct' else self.slots); self.integer(x, 0, 719); self.integer(y, 0, 1279)
            dt_us = (10000 if self.controller == 'direct' else 33333) if dt_us is None else dt_us
            self.integer(dt_us, 0, 60000000)
            if type(dispatch) is not bool or type(automatic) is not bool or type(sparse) is not bool:
                raise ValueError('invalid normal-UI sample policy')
            if sparse and self.controller not in ('st7121', 'st7123'):
                raise ValueError('sparse reports require Sitronix')
            if self.pending or len(self.trace) >= TRACE_LIMIT:
                return self.state()
            self.now += dt_us
            if self.controller == 'direct':
                changed = self.zig.normal_touch(contacts, x, y, self.now, dispatch)
            else:
                changed = self.zig.normal_controller_report(contacts, x, y, sparse, self.now, dispatch)
            self.trace.append({'action': 'pointer', 'contacts': contacts, 'x': x, 'y': y,
                               'dt_us': dt_us, 'dispatch': dispatch, 'automatic': automatic})
            if sparse:
                self.trace[-1]['sparse'] = True
            if changed:
                self._present(automatic)
            return self.state()

    def action(self, name, automatic=True, **kwargs):
        with LOCK:
            if type(automatic) is not bool:
                raise ValueError('invalid frame policy')
            if name == 'reset':
                return self.reset(kwargs.get('palette', 4), kwargs.get('controller', 'direct'), kwargs.get('slots'))
            if len(self.trace) >= TRACE_LIMIT:
                return self.state()
            if name == 'eof':
                self.trace.append({'action': name})
                return self.eof()
            if name == 'retry_frame':
                self.zig.normal_invalidate()
                self.trace.append({'action': name, 'automatic': automatic})
                self._present(automatic)
                return self.state()
            if self.pending:
                self.status = -2
                return self.state()
            event = {'action': name, 'automatic': bool(automatic)}
            if name == 'controller_fault':
                value = self.integer(kwargs.get('value', 0), 0, 6)
                if self.controller == 'direct' or not self.zig.normal_controller_fault(value):
                    raise ValueError('controller fixture required')
                event['value'] = value
                changed = False
            elif name == 'corrupt':
                changed = self.zig.normal_corrupt()
                if not changed:
                    self.status = -2
            elif name == 'tick':
                dt = self.integer(kwargs.get('dt_us', 2000001), 0, 60000000)
                dispatch = kwargs.get('dispatch', True)
                if type(dispatch) is not bool:
                    raise ValueError('invalid dispatch policy')
                self.now += dt
                changed = self.zig.normal_tick(self.now, dispatch)
                event.update(dt_us=dt, dispatch=dispatch)
            elif name == 'drain':
                changed = self.zig.normal_drain()
            else:
                names = {'logs': 0, 'splash': 1, 'append_log': 2, 'fail': 3}
                if name not in names:
                    raise ValueError('unknown normal-UI action')
                count = self.integer(kwargs.get('count', 1), 0, 1024)
                event['count'] = count
                changed = self.zig.normal_action(names[name], count)
                if not changed:
                    self.status = -2
            self.trace.append(event)
            if changed:
                self._present(automatic)
            return self.state()

    def key(self, name, automatic=True):
        if name not in ('logs', 'splash'):
            raise ValueError('unknown normal-UI key')
        return self.action(name, automatic)

    def replay(self, trace):
        if not isinstance(trace, list) or len(trace) > TRACE_LIMIT:
            raise ValueError('expected at most 4096 normal-UI events')
        # A normal-UI trace is explicitly typed. Card/PIN traces never gain
        # coordinate replay support through this separate endpoint.
        if (not trace or not isinstance(trace[0], dict) or trace[0].get('application') != 'normal' or
                trace[0].get('action') != 'reset'):
            raise ValueError('normal-UI trace marker required')
        for event in trace:
            if not isinstance(event, dict):
                raise ValueError('invalid normal-UI trace event')
            allowed = ({'action', 'contacts', 'x', 'y', 'dt_us', 'dispatch', 'automatic', 'sparse'} if event.get('action') == 'pointer'
                       else {'action', 'application', 'palette', 'controller', 'slots', 'dt_us', 'dispatch', 'automatic', 'count', 'value'})
            if not isinstance(event, dict) or set(event) - allowed:
                raise ValueError('invalid normal-UI trace event')
        for event in trace:
            if event['action'] == 'pointer':
                self.touch(**{k: v for k, v in event.items() if k != 'action'})
            else:
                self.action(event['action'], **{k: v for k, v in event.items() if k not in ('action', 'application')})
        return self.state()
