"""One synthetic Tab5 per process; production Zig + C, no device I/O."""
import ctypes as C
import fcntl
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import threading

ROOT = Path(__file__).resolve().parents[2]
FRAME_BYTES = 720 * 1280 * 2
PHASES = ('boot', 'ready', 'pin1', 'pin2', 'overview', 'details', 'error')
METRICS = ('frames', 'publications', 'rejections', 'mismatches', 'pending', 'dma_owned',
           'backlight', 'backlight_offs', 'fault', 'nodes', 'low_bytes', 'high_bytes')
LOCK = threading.RLock()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def build(directory=None):
    directory = Path(directory or ROOT / 'build/card-sim')
    directory.mkdir(parents=True, exist_ok=True)
    sources = sorted([*ROOT.joinpath('src').rglob('*'), *ROOT.joinpath('probes/card_sim').glob('*'),
                      *ROOT.joinpath('tools/card_sim').glob('*.py'), *ROOT.joinpath('tools/card_sim').glob('*.html')])
    witness = {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in sources if p.is_file()}
    zig = subprocess.check_output(['sh', str(ROOT / 'tools/bootstrap-zig.sh')], text=True).strip()
    witness['compiler_sha256'] = digest(Path(zig).read_bytes())
    identity = digest(json.dumps([platform.system(), platform.machine(), witness], sort_keys=True).encode())
    suffix = '.dylib' if platform.system() == 'Darwin' else '.so'
    render = directory / ('render-' + identity + suffix)
    scanout = directory / ('scanout-' + identity + suffix)
    receipt = directory / ('source-witness-' + identity + '.json')
    with (directory / 'build.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        valid = False
        if render.exists() and scanout.exists() and receipt.exists():
            try:
                cached = json.loads(receipt.read_text())
                valid = cached['artifacts'] == {p.name: digest(p.read_bytes()) for p in (render, scanout)}
            except (ValueError, KeyError):
                pass
        if not valid:
            staged_render, staged_scanout = [p.with_name('staged-' + p.name) for p in (render, scanout)]
            commands = [[zig, 'build-lib', '-dynamic', '-OReleaseSafe', str(ROOT / 'src/card_sim.zig'), '-femit-bin=' + str(staged_render)],
                        [zig, 'cc', '-dynamiclib' if suffix == '.dylib' else '-shared', '-fPIC', '-std=c17', '-O2', '-UNDEBUG',
                         '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', str(ROOT / 'probes/card_sim/scanout.c'), '-o', str(staged_scanout)]]
            with (directory / 'build.log').open('w') as log:
                for command in commands:
                    completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
                    if completed.returncode:
                        raise RuntimeError((directory / 'build.log').read_text()[-5000:])
            if any(witness[str(p.relative_to(ROOT))] != digest(p.read_bytes()) for p in sources if p.is_file()):
                raise RuntimeError('source changed during simulator build; retry with stable sources')
            staged_render.replace(render)
            staged_scanout.replace(scanout)
        evidence = {'identity': identity, 'sources': witness,
                    'host': [platform.system(), platform.machine()],
                    'artifacts': {p.name: digest(p.read_bytes()) for p in (render, scanout)},
                    'scope': 'host execution; register boundary modeled; not ESP32-P4 timing or panel qualification'}
        receipt.write_text(json.dumps(evidence, indent=2) + '\n')
    return render, scanout, identity, evidence


class Config(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ('plan', 'count', 'peer_start', 'peer_bytes', 'dots_x', 'dots_y',
        'dots_width', 'dots_height', 'label_x', 'label_y', 'label_width', 'label_height', 'paper', 'keys',
        'accent', 'scratch', 'stride', 'capacity', 'pixels', 'pixels_bytes')]


class View(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ('phase', 'count', 'job', 'present', 'confirms', 'missing', 'truncated')]


class Simulator:
    def __init__(self, directory=None, base_audit=None):
        render, scanout, self.identity, self.witness = build(directory)
        self.zig, self.c = C.CDLL(str(render)), C.CDLL(str(scanout))
        u8p, u32p = C.POINTER(C.c_uint8), C.POINTER(C.c_uint32)
        self.zig.sim_view.argtypes = [C.POINTER(View)]
        self.zig.sim_action.argtypes, self.zig.sim_action.restype = [C.c_uint32], C.c_bool
        self.zig.sim_touch.argtypes, self.zig.sim_touch.restype = [C.c_uint8, C.c_uint16, C.c_uint16], C.c_uint32
        self.zig.sim_render.argtypes = [u8p, C.c_size_t, u32p, C.c_size_t, C.POINTER(Config)]
        self.zig.sim_render.restype = C.c_uint32
        self.zig.sim_textures.argtypes, self.zig.sim_textures.restype = [u8p, C.c_size_t], C.c_bool
        self.c.sim_reset.argtypes = [C.c_uint32] * 4
        self.c.sim_present.argtypes = [C.POINTER(Config), u8p, u32p, u8p, C.c_uint32, C.c_uint32]
        self.c.sim_update.argtypes = [C.c_uint32, u8p, C.c_uint32, u8p]
        self.c.sim_pixels.argtypes, self.c.sim_metrics.argtypes = [u8p], [u32p]
        self.frame = (C.c_uint8 * FRAME_BYTES)()
        self.plan = (C.c_uint32 * (1280 * 4))()
        self.dynamic = (C.c_uint8 * 65536)()
        self.config = Config()
        self.trace = []
        self.active_phase = None
        self.status = 0
        self.profiles = {'base': (0x4ff40000, 128 * 1024, 0x4ff6e000, 196 * 1024),
                         'font': (0x4ff40000, 128 * 1024, 0x4ff80000, 124 * 1024)}
        self.base_audit = None
        if base_audit:
            raw = Path(base_audit).read_bytes()
            audit = json.loads(raw)
            regions = audit['service_sram']
            if len(regions) != 2:
                raise ValueError('expected two audited base SRAM extents')
            values = []
            for i, region in enumerate(regions):
                start, end = int(region['origin'], 16), int(region['end'], 16)
                lower, upper = ((0x4ff40000, 0x4ff60000) if i == 0 else (0x4ff6e000, 0x4ff9f000))
                if (region['name'] != 'service.free' + str(i) or not lower <= start < end <= upper or
                        (start | end) & 63 or region['bytes'] != end - start):
                    raise ValueError('invalid audited base SRAM extent')
                values.extend((start, end - start))
            self.profiles['audited'] = tuple(values)
            self.base_audit = {'audit_sha256': digest(raw), 'elf_sha256': audit['elf_sha256'], 'extents': regions}
        self.reset('audited' if self.base_audit else 'base')

    def view(self):
        out = View()
        self.zig.sim_view(C.byref(out))
        return {name: getattr(out, name) for name, _ in View._fields_}

    def metrics(self):
        values = (C.c_uint32 * 12)()
        self.c.sim_metrics(values)
        return dict(zip(METRICS, values))

    def pixels(self):
        out = (C.c_uint8 * FRAME_BYTES)()
        self.c.sim_pixels(out)
        return bytes(out)

    def sram_digest(self):
        out = (C.c_uint8 * (512 * 1024))()
        self.c.sim_sram(out)
        return digest(bytes(out))

    def state(self):
        view = self.view()
        return {'view': {**view, 'phase': PHASES[view['phase']]}, 'metrics': self.metrics(),
                'displayed_phase': self.active_phase, 'status': self.status,
                'pixel_sha256': digest(self.pixels()), 'sram_sha256': self.sram_digest(),
                'profile': self.profile, 'source_identity': self.identity,
                'base_audit': self.base_audit,
                'scope': 'host simulation; synthetic data; no reader, card, APDU or PIN value'}

    def reset(self, profile):
        with LOCK:
            if profile not in self.profiles:
                raise ValueError('unknown base profile')
            self.c.sim_fault(0)
            self.status = self.c.sim_reset(*self.profiles[profile])
            if self.status:
                raise RuntimeError('DMA still owns SRAM' if self.status == -2 else 'base SRAM layout/quota rejected')
            self.zig.sim_model_reset()
            self.profile = profile
            self.active_phase = None
            self._present()
            self.trace = [{'action': 'reset', 'profile': profile}]
            return self.state()

    def _render(self):
        count = self.zig.sim_render(self.frame, FRAME_BYTES, self.plan, 1280, C.byref(self.config))
        if not count:
            self.status = -6
            return False
        if self.config.stride and not self.zig.sim_textures(self.dynamic, 2 * self.config.stride):
            raise RuntimeError('invalid dynamic texture geometry')
        return True

    def _present(self):
        if not self._render():
            return
        view = self.view()
        self.status = self.c.sim_present(C.byref(self.config), self.frame, self.plan, self.dynamic,
                                        2 * self.config.stride, view['phase'] in (1, 6))
        if self.status == 0:
            self.active_phase = PHASES[view['phase']]

    def eof(self):
        self.status = self.c.sim_eof()
        if self.status == 0:
            self.active_phase = PHASES[self.view()['phase']]
        return self.state()

    def action(self, name, automatic=True, **kwargs):
        with LOCK:
            if name == 'reset':
                return self.reset(kwargs.get('profile', 'base'))
            if name == 'fault':
                value = int(kwargs.get('value', 0))
                if not 0 <= value <= 5:
                    raise ValueError('invalid fault')
                self.c.sim_fault(value)
                self.trace.append({'action': name, 'value': value})
                return self.state()
            if name == 'eof':
                self.trace.append({'action': name})
                return self.eof()
            if name == 'corrupt':
                self.status = self.c.sim_corrupt()
            elif name == 'shutdown':
                self.status = self.c.sim_shutdown()
            elif name == 'retry_frame':
                self._present()
            elif self.metrics()['pending'] or self.metrics()['fault'] or self.metrics()['mismatches']:
                self.status = -2
                return self.state()
            else:
                names = {'ready': 0, 'insert_classic': 1, 'insert_mynumber': 2, 'remove': 3, 'details': 4, 'overview': 5, 'close': 6}
                if name not in names:
                    raise ValueError('unknown action')
                if not self.zig.sim_action(names[name]):
                    self.status = -2
                    return self.state()
                self._present()
            self.trace.append({'action': name, 'automatic': bool(automatic)})
            if automatic and self.metrics()['pending']:
                return self.eof()
            return self.state()

    def touch(self, contacts, x, y, automatic=True):
        # Coordinates/key values are never recorded; only the resulting count
        # effect is kept in the replay trace. This model has no PIN array.
        with LOCK:
            if not (0 <= contacts <= 5 and 0 <= x < 720 and 0 <= y < 1280):
                raise ValueError('invalid touch sample')
            if (self.metrics()['pending'] or self.metrics()['fault'] or self.metrics()['mismatches'] or
                    self.status in (-3, -4, -5, -6) or not self.metrics()['dma_owned'] or
                    self.active_phase != PHASES[self.view()['phase']] or
                    self.view()['phase'] not in (2, 3)):
                return self.state()
            before = self.view()
            effect = self.zig.sim_touch(contacts, x, y)
            if not effect:
                return self.state()
            after = self.view()
            if before['phase'] == after['phase'] and self._render():
                self.status = self.c.sim_update(after['count'], self.dynamic, 2 * self.config.stride, self.frame)
            else:
                self._present()
            self.trace.append({'action': {1: 'digit', 2: 'erase', 3: 'cancel', 4: 'confirm'}[effect], 'automatic': bool(automatic)})
            if automatic and self.metrics()['pending']:
                return self.eof()
            return self.state()

    def key(self, name, automatic=True):
        point = {'digit': (100, 550), 'erase': (580, 970), 'cancel': (100, 970), 'confirm': (350, 1150)}.get(name)
        if point is None:
            raise ValueError('unknown count-only key')
        self.touch(1, *point, automatic=automatic)
        return self.touch(0, 0, 0, automatic=automatic)

    def replay(self, trace):
        if not isinstance(trace, list) or len(trace) > 4096:
            raise ValueError('expected at most 4096 semantic events')
        # Reject coordinates, numeric keys and arbitrary metadata in saved input.
        for item in trace:
            if not isinstance(item, dict) or set(item) - {'action', 'automatic', 'profile', 'value'}:
                raise ValueError('replay accepts semantic events only')
        for item in trace:
            action = item['action']
            if action in ('digit', 'erase', 'cancel', 'confirm'):
                self.key(action, item.get('automatic', True))
            else:
                self.action(action, item.get('automatic', True), **{k: v for k, v in item.items() if k not in ('action', 'automatic')})
        return self.state()
