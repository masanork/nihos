mod core;
pub mod emu;
use core::{Core, Key};
use gpui::{prelude::*, *};
use std::{sync::Arc, time::Instant};

const PANE_W: f32 = 512.;
const PANE_H: f32 = 360.;
struct Workspace {
    core: Core,
    started: Instant,
    graph: Arc<RenderImage>,
    editor: Arc<RenderImage>,
    width: u32,
    height: u32,
    focus: FocusHandle,
    editor_focus: bool,
    editor_generation: u64,
    tick_pending: bool,
    frames: u64,
    labels: Labels,
    status: Arc<RenderImage>,
    scale: f32,
    status_key: (u32, u32, bool),
    emulator: Option<emu::Emulator>,
    emu_image: Option<Arc<RenderImage>>,
    emu_render_revision: FrameRevision,
    emu_mode: bool,
    emu_portrait: bool,
    emu_touch_down: bool,
    emu_powered: bool,
    emu_error: Option<String>,
    emu_session_label: Arc<RenderImage>,
}
impl Workspace {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut core = Core::new();
        let scale = window.scale_factor().min(2.);
        let width = (PANE_W * scale).round().clamp(240., 1280.) as u32;
        let height = (PANE_H * scale).round().clamp(180., 720.) as u32;
        let focus = cx.focus_handle();
        window.focus(&focus);
        let editor = frame(core.bgra(true, width, height), width, height);
        let graph = frame(core.bgra(false, width, height), width, height);

        let mut emulator = None;
        let mut emu_image = None;
        let mut emu_error = None;
        match load_emulator() {
            Ok(mut emu) => {
                emu.step_frame(1_000_000);
                if let Some(fault) = emu.fault() {
                    emu_error = Some(format!("Emulator stopped: {fault}"));
                }
                let mut bgra = vec![0u8; emu::bus::FB_WIDTH * emu::bus::FB_HEIGHT * 4];
                emu.render_to_bgra(&mut bgra);
                emu_image = Some(frame(
                    bgra,
                    emu::bus::FB_WIDTH as u32,
                    emu::bus::FB_HEIGHT as u32,
                ));
                emulator = Some(emu);
            }
            Err(error) => emu_error = Some(error),
        }

        let emu_render_revision = FrameRevision(
            emulator
                .as_ref()
                .map(|emu| (emu.bus.scanout_revision(), false)),
        );
        let emu_powered = emulator.is_some() && emu_error.is_none();
        let emu_mode = true;
        if emu_mode {
            #[cfg(feature = "experimental-meos")]
            let title = if emulator.as_ref().is_some_and(|emu| emu.is_meos_fixture()) {
                "Tab5 Emulator · Experimental MeOS (volatile)"
            } else {
                "Tab5 Emulator"
            };
            #[cfg(not(feature = "experimental-meos"))]
            let title = "Tab5 Emulator";
            window.set_window_title(&format!("{title} · Session {}", std::process::id()));
        } else {
            window.set_window_title("xy - GPUI");
        }
        cx.observe_window_activation(window, |this, window, cx| {
            if !window.is_window_active() {
                this.touch_end();
                this.core.focus_lost(this.now());
                this.refresh_graph(window);
                cx.notify();
            } else {
                this.core.focus_gained(this.now());
            }
        })
        .detach();
        cx.on_app_quit(|this, _| {
            this.core.cancel(this.now());
            async {}
        })
        .detach();
        let labels = Labels::new(&mut core, scale);
        let status = status_image(&mut core, scale, false);
        let emu_session_label = label(
            &mut core,
            &format!("Session {}", std::process::id()),
            [150., 32., 13.],
            scale,
            [0x9ca9b9, 0x101216],
            false,
        );
        Self {
            labels,
            status,
            scale,
            status_key: (0, 2, false),
            core,
            started: Instant::now(),
            graph,
            editor,
            width,
            height,
            focus,
            editor_focus: false,
            editor_generation: 1,
            tick_pending: false,
            frames: 1,
            emulator,
            emu_image,
            emu_render_revision,
            emu_mode,
            emu_portrait: false,
            emu_touch_down: false,
            emu_powered,
            emu_error,
            emu_session_label,
        }
    }
    fn now(&self) -> u64 {
        self.started.elapsed().as_micros().min(u64::MAX as u128) as u64
    }
    fn retry_firmware(&mut self, window: &mut Window) {
        match load_emulator() {
            Ok(emu) => {
                self.emulator = Some(emu);
                self.emu_render_revision.invalidate();
                self.emu_powered = true;
                self.emu_error = None;
                self.render_emulator_image(window);
            }
            Err(error) => self.emu_error = Some(error),
        }
    }
    fn refresh_graph(&mut self, window: &mut Window) {
        let next = frame(
            self.core.bgra(false, self.width, self.height),
            self.width,
            self.height,
        );
        retire(std::mem::replace(&mut self.graph, next), window);
        self.frames += 1;
        self.refresh_status(window);
        if self.core.editor_generation() != self.editor_generation {
            self.refresh_editor(window);
        }
    }
    fn refresh_status(&mut self, window: &mut Window) {
        let state = self.core.state();
        let key = (state.paused, state.speed, self.editor_focus);
        if key != self.status_key {
            let status = status_image(&mut self.core, self.scale, self.editor_focus);
            retire(std::mem::replace(&mut self.status, status), window);
            self.status_key = key;
        }
    }
    fn refresh_editor(&mut self, window: &mut Window) {
        let next = frame(
            self.core.bgra(true, self.width, self.height),
            self.width,
            self.height,
        );
        retire(std::mem::replace(&mut self.editor, next), window);
        self.editor_generation = self.core.editor_generation();
    }
    fn refresh_emulator(&mut self, window: &mut Window) {
        if !self.emu_powered || self.emulator.as_ref().is_some_and(|emu| emu.paused) {
            return;
        }
        if let Some(emu) = &mut self.emulator {
            emu.step_frame(500_000);
            if let Some(fault) = emu.fault() {
                self.emu_error = Some(format!("Emulator stopped: {fault}"));
                self.emu_powered = false;
                self.render_emulator_image(window);
                return;
            }
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            if let Some(line) = output
                .lines()
                .find(|line| line.starts_with("NIHOS_NATIVE_FAIL "))
            {
                self.emu_error = Some(format!("Guest stopped: {line}"));
                self.emu_powered = false;
                self.render_emulator_image(window);
                return;
            }
        }
        self.render_emulator_image(window);
    }
    fn render_emulator_image(&mut self, window: &mut Window) {
        if let Some((bgra, w, h)) = self.emulator.as_ref().and_then(|emu| {
            render_changed_frame(emu, self.emu_portrait, &mut self.emu_render_revision)
        }) {
            let next = frame(bgra, w, h);
            if let Some(old) = self.emu_image.replace(next) {
                retire(old, window);
            }
        }
    }

    fn touch_at(&mut self, position: Point<Pixels>, window: &Window, start: bool) {
        if !self.emu_powered || self.emulator.as_ref().is_none_or(|emu| emu.paused) {
            return;
        }
        if !start && !self.emu_touch_down {
            return;
        }
        if let Some(point) = touch_coordinates(
            position,
            window.viewport_size(),
            self.emu_portrait,
            self.emu_error.is_some(),
        ) {
            self.emu_touch_down = true;
            if let Some(emu) = &mut self.emulator {
                emu.bus.touch(Some(point));
            }
        }
    }
    fn touch_end(&mut self) {
        if self.emu_touch_down {
            self.emu_touch_down = false;
            if let Some(emu) = &mut self.emulator {
                emu.bus.touch(None);
            }
        }
    }
    fn press(&mut self, key: Key, window: &mut Window, cx: &mut Context<Self>) {
        self.core.press(key, self.now());
        self.refresh_graph(window);
        cx.notify();
    }
    fn run_scheme(&mut self, stop: bool, window: &mut Window, cx: &mut Context<Self>) {
        if stop {
            let _ = self.core.eval("(app/stop!)", self.now());
        } else {
            let _ = self.core.eval_buffer(self.now());
        }
        self.refresh_graph(window);
        cx.notify();
    }
    fn schedule(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if (self.emu_mode
            && (!self.emu_powered || self.emulator.as_ref().is_none_or(|emu| emu.paused)))
            || self.tick_pending
            || (!self.emu_mode && (self.core.state().paused != 0 || self.core.state().stopped != 0))
        {
            return;
        }
        self.tick_pending = true;
        cx.on_next_frame(window, |this, window, cx| {
            this.tick_pending = false;
            if this.emu_mode {
                this.refresh_emulator(window);
                cx.notify();
            } else {
                if this.core.state().stopped != 0 {
                    return;
                }
                if this.core.tick(this.now()) {
                    this.refresh_graph(window);
                    cx.notify();
                }
                if this.core.state().paused == 0 {
                    cx.notify();
                }
            }
        });
        window.request_animation_frame();
    }
    fn new_session(&mut self, cx: &mut Context<Self>) {
        let result = std::env::current_exe().and_then(|path| {
            std::process::Command::new(path)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
        });
        match result {
            Ok(mut child) => {
                std::thread::spawn(move || {
                    let _ = child.wait();
                });
            }
            Err(err) => {
                self.emu_error = Some(format!("Cannot start session: {err}"));
                cx.notify();
            }
        }
    }
    fn key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let stroke = &event.keystroke;
        if stroke.modifiers.platform && stroke.key == "q" {
            cx.quit();
            return;
        }
        if self.emu_mode {
            if stroke.modifiers.platform && stroke.key == "n" {
                if !event.is_held {
                    self.new_session(cx);
                }
                cx.stop_propagation();
                return;
            }
            if !self.emu_powered || self.emulator.as_ref().is_some_and(|emu| emu.paused) {
                cx.stop_propagation();
                return;
            }
            if let Some(emu) = &mut self.emulator {
                match stroke.key.as_str() {
                    "space" => emu.send_key(b' '),
                    "enter" => emu.send_key(b'\r'),
                    "backspace" => emu.send_key(8),
                    "escape" => emu.send_key(0x1b),
                    "tab" => emu.send_key(b'\t'),
                    "left" | "right" | "up" | "down" => send_emulator_arrow(emu, &stroke.key),
                    _ => {
                        if let Some(c) = stroke.key_char.as_deref().and_then(|s| s.chars().next()) {
                            let ascii = match c {
                                '\r' | '\n' => b'\r',
                                _ if c.is_ascii() => c as u8,
                                _ => 0,
                            };
                            if ascii != 0 {
                                emu.send_key(ascii);
                            }
                        }
                    }
                }
            }
            cx.stop_propagation();
            return;
        }

        if stroke.key == "f5"
            || (stroke.key == "enter" && stroke.modifiers.control)
            || (stroke.key == "c" && stroke.modifiers.control)
        {
            if !event.is_held {
                self.run_scheme(stroke.key == "c", window, cx);
            }
            cx.stop_propagation();
            return;
        }
        if stroke.key == "tab" {
            if !event.is_held {
                self.editor_focus = !self.editor_focus;
                self.refresh_status(window);
                cx.notify();
            }
            cx.stop_propagation();
            return;
        }
        if self.editor_focus {
            let key = match stroke.key.as_str() {
                "left" => Some(0),
                "right" => Some(1),
                "backspace" => Some(2),
                "enter" => Some(4),
                "z" if stroke.modifiers.control || stroke.modifiers.platform => Some(3),
                _ => None,
            };
            let changed = if let Some(key) = key {
                self.core.editor_key(key)
            } else if !stroke.modifiers.control && !stroke.modifiers.platform {
                stroke
                    .key_char
                    .as_deref()
                    .is_some_and(|text| self.core.editor_insert(text))
            } else {
                false
            };
            if changed {
                self.refresh_editor(window);
                cx.notify();
            }
        } else if let Some(key) = graph_key(&stroke.key) {
            self.core.key(key, true, self.now());
            self.refresh_graph(window);
            cx.notify();
        }
        cx.stop_propagation();
    }
    fn key_up(&mut self, event: &KeyUpEvent, _window: &mut Window, _cx: &mut Context<Self>) {
        if let Some(key) = graph_key(&event.keystroke.key) {
            self.core.key(key, false, self.now());
        }
    }
}
struct Labels {
    title: Arc<RenderImage>,
    editor: Arc<RenderImage>,
    graph: Arc<RenderImage>,
    pause: Arc<RenderImage>,
    resume: Arc<RenderImage>,
    reset: Arc<RenderImage>,
    run: Arc<RenderImage>,
    stop: Arc<RenderImage>,
    emu_toggle: Arc<RenderImage>,
    editor_help: Arc<RenderImage>,
    graph_help: Arc<RenderImage>,
    footer: Arc<RenderImage>,
    emu_portrait: Arc<RenderImage>,
    emu_landscape: Arc<RenderImage>,
    emu_on: Arc<RenderImage>,
    emu_off: Arc<RenderImage>,
    emu_reset: Arc<RenderImage>,
    emu_new: Arc<RenderImage>,
    emu_pause: Arc<RenderImage>,
    emu_resume: Arc<RenderImage>,
}
impl Labels {
    fn new(core: &mut Core, scale: f32) -> Self {
        let bg = [0x1c2733, 0xf4f6f8];
        Self {
            emu_pause: label(
                core,
                "Pause",
                [100., 32., 15.],
                scale,
                [0xe7e9ed, 0x292d35],
                true,
            ),
            emu_resume: label(
                core,
                "Resume",
                [100., 32., 15.],
                scale,
                [0xe7e9ed, 0x292d35],
                true,
            ),
            emu_new: label(
                core,
                "New session",
                [110., 32., 15.],
                scale,
                [0xe7e9ed, 0x334c70],
                true,
            ),
            emu_portrait: label(
                core,
                "Portrait",
                [100., 32., 15.],
                scale,
                [0xe7e9ed, 0x292d35],
                true,
            ),
            emu_landscape: label(
                core,
                "Landscape",
                [100., 32., 15.],
                scale,
                [0xe7e9ed, 0x292d35],
                true,
            ),
            emu_on: label(
                core,
                "Power on",
                [100., 32., 15.],
                scale,
                [0xe7e9ed, 0x292d35],
                true,
            ),
            emu_off: label(
                core,
                "Power off",
                [100., 32., 15.],
                scale,
                [0xe7e9ed, 0x292d35],
                true,
            ),
            emu_reset: label(
                core,
                "Reset",
                [100., 32., 15.],
                scale,
                [0xe7e9ed, 0x292d35],
                true,
            ),
            title: label(core, "xy workspace", [600., 36., 24.], scale, bg, false),
            editor: label(core, "Editor", [512., 28., 16.], scale, bg, false),
            graph: label(core, "Graph", [512., 28., 16.], scale, bg, false),
            emu_toggle: label(
                core,
                "Firmware",
                [100., 40., 16.],
                scale,
                [0xffffff, 0x117733],
                true,
            ),
            pause: label(
                core,
                "Pause",
                [80., 40., 16.],
                scale,
                [0xffffff, 0x0755aa],
                true,
            ),
            resume: label(
                core,
                "Resume",
                [80., 40., 16.],
                scale,
                [0xffffff, 0x0755aa],
                true,
            ),
            reset: label(
                core,
                "Reset",
                [80., 40., 16.],
                scale,
                [0x1c2733, 0xe0e7ee],
                true,
            ),
            run: label(
                core,
                "Run",
                [80., 40., 16.],
                scale,
                [0xffffff, 0x0755aa],
                true,
            ),
            stop: label(
                core,
                "Stop",
                [80., 40., 16.],
                scale,
                [0x1c2733, 0xe0e7ee],
                true,
            ),
            editor_help: label(
                core,
                "Type - arrows - Backspace - Ctrl-Z undo",
                [512., 28., 14.],
                scale,
                bg,
                false,
            ),
            graph_help: label(
                core,
                "Space pause - Left/Right speed - R reset",
                [512., 28., 14.],
                scale,
                bg,
                false,
            ),
            footer: label(
                core,
                "Ctrl-Enter: run Scheme - Ctrl-C: stop callback",
                [600., 28., 14.],
                scale,
                bg,
                false,
            ),
        }
    }
}
fn label(
    core: &mut Core,
    text: &str,
    dimensions: [f32; 3],
    scale: f32,
    colors: [u32; 2],
    centered: bool,
) -> Arc<RenderImage> {
    let dims = dimensions.map(|n| (n * scale).round() as u32);
    frame(core.label(text, dims, colors, centered), dims[0], dims[1])
}
fn status_image(core: &mut Core, scale: f32, editor: bool) -> Arc<RenderImage> {
    let state = core.state();
    let text = format!(
        "{} - speed {} - {}",
        if state.paused != 0 {
            "Paused"
        } else {
            "Running"
        },
        state.speed,
        if editor { "Editor" } else { "Graph" }
    );
    label(
        core,
        &text,
        [320., 40., 16.],
        scale,
        [0x1c2733, 0xf4f6f8],
        false,
    )
}
fn shown(image: &Arc<RenderImage>, w: f32, h: f32) -> gpui::Img {
    img(image.clone()).w(px(w)).h(px(h))
}
// Invert the fit and framebuffer rotations to obtain physical panel coordinates.
fn screen_geometry(
    viewport: Size<Pixels>,
    portrait: bool,
    has_error: bool,
) -> (f32, f32, f32, f32) {
    let (vw, vh): (f32, f32) = (viewport.width.into(), viewport.height.into());
    let (w, h) = if portrait {
        (720., 1280.)
    } else {
        (1280., 720.)
    };
    let error_height = if has_error { 48. } else { 0. };
    let fit = ((vw - 32.).max(1.) / w).min((vh - 80. - error_height).max(1.) / h);
    let (screen_w, screen_h) = (w * fit, h * fit);
    (
        screen_w,
        screen_h,
        (vw - screen_w) / 2.,
        48. + (vh - 48. - screen_h - error_height) / 2.,
    )
}

fn bounded_error_text(text: &str) -> String {
    if text.len() <= 128 {
        return text.to_owned();
    }
    let mut end = 125;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}...", &text[..end])
}

struct FrameRevision(Option<(u64, bool)>);

impl FrameRevision {
    fn needs_update(&self, revision: (u64, bool)) -> bool {
        self.0 != Some(revision)
    }
    fn record(&mut self, revision: (u64, bool)) {
        self.0 = Some(revision);
    }
    fn invalidate(&mut self) {
        self.0 = None;
    }
}

fn render_changed_frame(
    emu: &emu::Emulator,
    portrait: bool,
    revision: &mut FrameRevision,
) -> Option<(Vec<u8>, u32, u32)> {
    let current = (emu.bus.scanout_revision(), portrait);
    if !revision.needs_update(current) {
        return None;
    }
    let mut bgra = vec![0; emu::bus::FB_WIDTH * emu::bus::FB_HEIGHT * 4];
    emu.render_to_bgra(&mut bgra);
    let result = orient_frame(bgra, portrait);
    revision.record(current);
    Some(result)
}

fn select_firmware(
    explicit: Option<std::path::PathBuf>,
    bundle: Option<&std::path::Path>,
    candidates: &[std::path::PathBuf],
) -> Option<std::path::PathBuf> {
    explicit
        .or_else(|| {
            bundle
                .map(|p| p.join("nihos-native.elf"))
                .filter(|p| p.is_file())
        })
        .or_else(|| candidates.iter().find(|p| p.is_file()).cloned())
}

fn load_emulator() -> Result<emu::Emulator, String> {
    if let Some(app) = std::env::var_os("NIHOS_EXPERIMENTAL_MEOS_APP") {
        #[cfg(feature = "experimental-meos")]
        {
            let rom = std::env::var_os("NIHOS_EXPERIMENTAL_MEOS_ROM")
                .ok_or("Experimental MeOS requires NIHOS_EXPERIMENTAL_MEOS_ROM")?;
            return emu::Emulator::new_meos(app, rom)
                .map_err(|error| format!("Cannot load experimental MeOS: {error}"));
        }
        #[cfg(not(feature = "experimental-meos"))]
        {
            let _ = app;
            return Err("Experimental MeOS requires the experimental-meos build feature".into());
        }
    }
    // An explicit path remains authoritative even if it is missing or invalid.
    let bundle = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent()?.parent().map(|p| p.join("Resources")));
    let candidates = [
        "build/xy-emulator-firmware/nihos-native.elf".into(),
        "../../build/xy-emulator-firmware/nihos-native.elf".into(),
    ];
    let path = select_firmware(
        std::env::var_os("NIHOS_EMULATOR_ELF").map(std::path::PathBuf::from),
        bundle.as_deref(),
        &candidates,
    )
    .ok_or_else(|| "Firmware not bundled; build the xy fixture first".to_owned())?;
    let dictionary = bundle
        .as_ref()
        .map(|p| p.join("jisyo_s_nfst.bin"))
        .filter(|p| p.is_file())
        .or_else(|| {
            [
                "src/xy/fixtures/jisyo_s_nfst.bin",
                "../../src/xy/fixtures/jisyo_s_nfst.bin",
            ]
            .iter()
            .map(std::path::PathBuf::from)
            .find(|p| p.is_file())
        });
    emu::Emulator::new(path, dictionary).map_err(|error| format!("Cannot load firmware: {error}"))
}

fn send_emulator_arrow(emu: &mut emu::Emulator, key: &str) {
    #[cfg(feature = "experimental-meos")]
    if emu.is_meos_fixture() {
        let suffix = match key {
            "up" => b'A',
            "down" => b'B',
            "right" => b'C',
            "left" => b'D',
            _ => return,
        };
        for byte in [0x1b, b'[', suffix] {
            emu.send_key(byte);
        }
        return;
    }
    let byte = match key {
        "left" => 0x02,
        "right" => 0x06,
        "up" => 0x10,
        "down" => 0x0e,
        _ => return,
    };
    emu.send_key(byte);
}

fn reset_emulator(emu: &mut emu::Emulator, stopped: bool) -> std::io::Result<()> {
    emu.reset()?;
    if stopped {
        emu.paused = false;
    }
    Ok(())
}

fn error_label_width(available_w: f32, scale: f32) -> f32 {
    (available_w - 32.).clamp(32. / scale, (1280. / scale).min(720.))
}

fn touch_coordinates(
    position: Point<Pixels>,
    viewport: Size<Pixels>,
    portrait: bool,
    has_error: bool,
) -> Option<(u16, u16)> {
    let (w, h) = if portrait {
        (720., 1280.)
    } else {
        (1280., 720.)
    };
    let (screen_w, _, left, top) = screen_geometry(viewport, portrait, has_error);
    let fit = screen_w / w;
    let (px, py): (f32, f32) = (position.x.into(), position.y.into());
    let x = (px - left) / fit;
    let y = (py - top) / fit;
    if x < 0. || y < 0. || x >= w || y >= h {
        return None;
    }
    if portrait {
        Some((x as u16, y as u16))
    } else {
        Some((y as u16, 1279 - x as u16))
    }
}
// Rotate the displayed framebuffer counterclockwise; the guest orientation is unchanged.
fn orient_frame(src: Vec<u8>, portrait: bool) -> (Vec<u8>, u32, u32) {
    let (w, h) = (emu::bus::FB_WIDTH, emu::bus::FB_HEIGHT);
    if !portrait {
        return (src, w as u32, h as u32);
    }
    let mut dst = vec![0; src.len()];
    for y in 0..h {
        for x in 0..w {
            let from = (y * w + x) * 4;
            let to = ((w - 1 - x) * h + y) * 4;
            dst[to..to + 4].copy_from_slice(&src[from..from + 4]);
        }
    }
    (dst, h as u32, w as u32)
}
impl Render for Workspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.schedule(window, cx);

        if self.emu_mode {
            let viewport = window.viewport_size();
            let available_w: f32 = viewport.width.into();
            let (screen_w, screen_h, _, _) =
                screen_geometry(viewport, self.emu_portrait, self.emu_error.is_some());
            // The shared label renderer caps its backing image at 1280 px.
            let error_width = error_label_width(available_w, self.scale);
            let error_image = self.emu_error.as_ref().map(|error| {
                label(
                    &mut self.core,
                    &bounded_error_text(error),
                    [error_width, 48., 16.],
                    self.scale,
                    [0xffa8a8, 0x101216],
                    true,
                )
            });
            let control = |id: &'static str, image: &Arc<RenderImage>| {
                div()
                    .id(id)
                    .cursor_pointer()
                    .rounded_md()
                    .overflow_hidden()
                    .child(shown(image, 100., 32.))
            };
            return div()
                .track_focus(&self.focus)
                .on_key_down(cx.listener(Self::key_down))
                .size_full()
                .flex()
                .flex_col()
                .bg(rgb(0x101216))
                .text_color(rgb(0xe7e9ed))
                .child(
                    div()
                        .h(px(48.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .gap_2()
                        .child(shown(&self.emu_session_label, 150., 32.))
                        .child(
                            div()
                                .id("emu-new-session")
                                .cursor_pointer()
                                .rounded_md()
                                .overflow_hidden()
                                .on_click(cx.listener(|this, _, _, cx| this.new_session(cx)))
                                .child(shown(&self.labels.emu_new, 110., 32.)),
                        )
                        .child(
                            control(
                                "emu-rotate",
                                if self.emu_portrait {
                                    &self.labels.emu_landscape
                                } else {
                                    &self.labels.emu_portrait
                                },
                            )
                            .on_click(cx.listener(
                                |this, _, window, cx| {
                                    this.touch_end();
                                    this.emu_portrait = !this.emu_portrait;
                                    this.render_emulator_image(window);
                                    cx.notify();
                                },
                            )),
                        )
                        .child(
                            control(
                                "emu-pause",
                                if self.emulator.as_ref().is_some_and(|emu| emu.paused) {
                                    &self.labels.emu_resume
                                } else {
                                    &self.labels.emu_pause
                                },
                            )
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.touch_end();
                                if this.emu_powered
                                    && let Some(emu) = &mut this.emulator
                                {
                                    emu.paused = !emu.paused;
                                }
                                cx.notify();
                            })),
                        )
                        .child(
                            control(
                                "emu-power",
                                if self.emu_powered {
                                    &self.labels.emu_off
                                } else {
                                    &self.labels.emu_on
                                },
                            )
                            .on_click(cx.listener(
                                |this, _, window, cx| {
                                    this.touch_end();
                                    if this.emu_powered {
                                        this.emu_powered = false;
                                    } else if let Some(emu) = &mut this.emulator {
                                        match emu.reset() {
                                            Ok(()) => {
                                                emu.paused = false;
                                                this.emu_render_revision.invalidate();
                                                this.emu_powered = true;
                                                this.emu_error = None;
                                            }
                                            Err(err) => {
                                                this.emu_error =
                                                    Some(format!("Power on failed: {err}"))
                                            }
                                        }
                                        this.refresh_emulator(window);
                                    } else {
                                        this.retry_firmware(window);
                                    }
                                    cx.notify();
                                },
                            )),
                        )
                        .child(
                            control("emu-reset", &self.labels.emu_reset).on_click(cx.listener(
                                |this, _, window, cx| {
                                    this.touch_end();
                                    if this.emu_powered || this.emu_error.is_some() {
                                        if let Some(emu) = &mut this.emulator {
                                            match reset_emulator(emu, !this.emu_powered) {
                                                Ok(()) => {
                                                    this.emu_render_revision.invalidate();
                                                    this.emu_powered = true;
                                                    this.emu_error = None;
                                                }
                                                Err(err) => {
                                                    this.emu_powered = false;
                                                    this.emu_error =
                                                        Some(format!("Reset failed: {err}"));
                                                }
                                            }
                                        } else {
                                            this.retry_firmware(window);
                                        }
                                        this.render_emulator_image(window);
                                    }
                                    cx.notify();
                                },
                            )),
                        ),
                )
                .child(
                    div()
                        .flex_1()
                        .flex()
                        .flex_col()
                        .items_center()
                        .justify_center()
                        .p_4()
                        .child(if self.emulator.is_none() {
                            if self.emu_error.is_some() {
                                div()
                            } else {
                                let image = label(
                                    &mut self.core,
                                    "Firmware ELF not found or could not be loaded",
                                    [720., 48., 16.],
                                    self.scale,
                                    [0xaeb5c2, 0x101216],
                                    true,
                                );
                                div().child(shown(&image, 720., 48.))
                            }
                        } else if !self.emu_powered && self.emu_error.is_none() {
                            div().w(px(screen_w)).h(px(screen_h)).bg(rgb(0x000000))
                        } else if let Some(image) = &self.emu_image {
                            div().child(
                                div()
                                    .id("emu-screen")
                                    .bg(rgb(0x000000))
                                    .on_mouse_down(
                                        MouseButton::Left,
                                        cx.listener(|this, event: &MouseDownEvent, window, _| {
                                            this.touch_at(event.position, window, true)
                                        }),
                                    )
                                    .on_mouse_move(cx.listener(
                                        |this, event: &MouseMoveEvent, window, _| {
                                            this.touch_at(event.position, window, false)
                                        },
                                    ))
                                    .on_mouse_up(
                                        MouseButton::Left,
                                        cx.listener(|this, _: &MouseUpEvent, _, _| {
                                            this.touch_end()
                                        }),
                                    )
                                    .on_mouse_up_out(
                                        MouseButton::Left,
                                        cx.listener(|this, _: &MouseUpEvent, _, _| {
                                            this.touch_end()
                                        }),
                                    )
                                    .child(shown(image, screen_w, screen_h)),
                            )
                        } else {
                            div()
                        })
                        .children(
                            error_image
                                .as_ref()
                                .map(|image| shown(image, error_width, 48.)),
                        ),
                );
        }

        let paused = self.core.state().paused != 0;
        div()
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::key_down))
            .on_key_up(cx.listener(Self::key_up))
            .size_full()
            .flex()
            .flex_col()
            .gap_3()
            .p_4()
            .bg(rgb(0xf7f7ff))
            .child(shown(&self.labels.title, 600., 36.))
            .child(
                div()
                    .flex()
                    .gap_3()
                    .items_center()
                    .child(
                        div()
                            .id("run-scheme")
                            .cursor_pointer()
                            .on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.run_scheme(false, window, cx)
                                }),
                            )
                            .child(shown(&self.labels.run, 80., 40.)),
                    )
                    .child(
                        div()
                            .id("stop-scheme")
                            .cursor_pointer()
                            .on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.run_scheme(true, window, cx)
                                }),
                            )
                            .child(shown(&self.labels.stop, 80., 40.)),
                    )
                    .child(
                        div()
                            .id("pause")
                            .rounded_md()
                            .overflow_hidden()
                            .cursor_pointer()
                            .on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.press(Key::Pause, window, cx)
                                }),
                            )
                            .child(shown(
                                if paused {
                                    &self.labels.resume
                                } else {
                                    &self.labels.pause
                                },
                                80.,
                                40.,
                            )),
                    )
                    .child(
                        div()
                            .id("reset")
                            .rounded_md()
                            .overflow_hidden()
                            .cursor_pointer()
                            .on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.press(Key::Reset, window, cx)
                                }),
                            )
                            .child(shown(&self.labels.reset, 80., 40.)),
                    )
                    .child(
                        div()
                            .id("toggle-emu")
                            .rounded_md()
                            .overflow_hidden()
                            .cursor_pointer()
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.emu_mode = true;
                                window.set_window_title("nihOS - M5Stack Tab5 Emulator");
                                cx.notify();
                            }))
                            .child(shown(&self.labels.emu_toggle, 100., 40.)),
                    )
                    .child(shown(&self.status, 320., 40.)),
            )
            .child(
                div()
                    .flex()
                    .gap_4()
                    .child(
                        div()
                            .id("editor-pane")
                            .flex()
                            .flex_col()
                            .gap_2()
                            .cursor_pointer()
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.editor_focus = true;
                                this.refresh_graph(window);
                                cx.notify();
                            }))
                            .child(shown(&self.labels.editor, 512., 28.))
                            .child(
                                div()
                                    .border_2()
                                    .border_color(rgb(if self.editor_focus {
                                        0x0755aa
                                    } else {
                                        0xd4dbe3
                                    }))
                                    .child(shown(&self.editor, PANE_W, PANE_H)),
                            )
                            .child(shown(&self.labels.editor_help, 512., 28.)),
                    )
                    .child(
                        div()
                            .id("graph-pane")
                            .flex()
                            .flex_col()
                            .gap_2()
                            .cursor_pointer()
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.editor_focus = false;
                                this.refresh_graph(window);
                                cx.notify();
                            }))
                            .child(shown(&self.labels.graph, 512., 28.))
                            .child(
                                div()
                                    .border_2()
                                    .border_color(rgb(if self.editor_focus {
                                        0xd4dbe3
                                    } else {
                                        0x0755aa
                                    }))
                                    .child(shown(&self.graph, PANE_W, PANE_H)),
                            )
                            .child(shown(&self.labels.graph_help, 512., 28.)),
                    ),
            )
            .child(shown(&self.labels.footer, 600., 28.))
    }
}

fn frame(bytes: Vec<u8>, width: u32, height: u32) -> Arc<RenderImage> {
    // GPUI's image::Frame container deliberately holds BGRA, not RGBA.
    let buffer = image::RgbaImage::from_raw(width, height, bytes).expect("validated frame size");
    Arc::new(RenderImage::new(vec![image::Frame::new(buffer)]))
}
fn retire(image: Arc<RenderImage>, window: &mut Window) {
    // Keep the image alive through this frame, then release its atlas entries.
    window.on_next_frame(move |window, _| {
        let _ = window.drop_image(image);
    });
}
fn graph_key(key: &str) -> Option<Key> {
    match key {
        "space" | " " => Some(Key::Pause),
        "left" => Some(Key::Slower),
        "right" => Some(Key::Faster),
        "r" | "home" => Some(Key::Reset),
        _ => None,
    }
}
fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    if args.get(1).is_some_and(|arg| arg == "--snapshot-dir") {
        core::check_and_snapshot(std::path::Path::new(
            args.get(2).expect("--snapshot-dir PATH"),
        ));
        return;
    }
    Application::new().run(|cx: &mut App| {
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        let bounds = Bounds::centered(None, size(px(1100.), px(680.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..Default::default()
            },
            |window, cx| cx.new(|cx| Workspace::new(window, cx)),
        )
        .expect("open GPUI workspace");
        cx.activate(true);
    });
}

#[cfg(test)]
mod emulator_display_tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn nihos_arrow_keys_keep_editor_controls() {
        let mut emu = emu::Emulator::empty_for_display_test();
        for key in ["left", "right", "up", "down"] {
            send_emulator_arrow(&mut emu, key);
        }
        assert_eq!(emu.bus.keyboard_fifo, [0x02, 0x06, 0x10, 0x0e]);
    }

    #[::core::prelude::v1::test]
    fn cached_frame_follows_dma_rotation_and_machine_replacement() {
        fn machine() -> emu::Emulator {
            emu::Emulator::empty_for_display_test()
        }
        fn publish(emu: &mut emu::Emulator, color: u32) {
            let bus = &mut emu.bus;
            let desc = 0x4ff1_0000;
            bus.write_u32(emu::bus::FB_BASE, color);
            bus.write_u32(emu::bus::FB_BASE + 4, color);
            bus.write_u32(desc, emu::bus::FB_BASE);
            bus.write_u32(desc + 8, 0x5010_5000);
            bus.write_u32(desc + 16, (emu::bus::FB_SIZE / 8 - 1) as u32);
            bus.write_u32(desc + 32, 0x310);
            bus.write_u32(desc + 36, 0xc000_0000);
            bus.write_u32(0x5008_1128, desc);
            bus.write_u32(0x5008_1018, 0x101);
        }
        let mut emu = machine();
        let mut revision = FrameRevision(None);
        publish(&mut emu, 0xf800_f800);
        let (red, _, _) = render_changed_frame(&emu, false, &mut revision).unwrap();
        assert_eq!(&red[..4], &[0, 0, 255, 255]);
        assert!(render_changed_frame(&emu, false, &mut revision).is_none());
        publish(&mut emu, 0xf800_f800);
        assert_eq!(emu.bus.scanout_frames, 2);
        assert!(render_changed_frame(&emu, false, &mut revision).is_none());
        publish(&mut emu, 0x001f_001f);
        let (blue, _, _) = render_changed_frame(&emu, false, &mut revision).unwrap();
        assert_eq!(&blue[..4], &[255, 0, 0, 255]);
        let (rotated, width, height) = render_changed_frame(&emu, true, &mut revision).unwrap();
        assert_eq!((width, height), (720, 1280));
        assert_eq!(&rotated[..4], &[255, 0, 0, 255]);

        let mut replacement = machine();
        publish(&mut replacement, 0x001f_001f);
        publish(&mut replacement, 0xf800_f800);
        publish(&mut replacement, 0xf800_f800);
        assert_eq!(replacement.bus.scanout_frames, emu.bus.scanout_frames);
        assert_eq!(
            replacement.bus.scanout_revision(),
            emu.bus.scanout_revision()
        );
        revision.invalidate();
        let (red_again, _, _) = render_changed_frame(&replacement, true, &mut revision).unwrap();
        assert_eq!(&red_again[..4], &[0, 0, 255, 255]);
    }

    #[::core::prelude::v1::test]
    fn frame_revision_tracks_scanout_rotation_and_new_machine() {
        let mut revision = FrameRevision(None);
        assert!(revision.needs_update((0, false)));
        revision.record((0, false));
        assert!(!revision.needs_update((0, false)));
        assert!(revision.needs_update((1, false)));
        revision.record((1, false));
        assert!(revision.needs_update((1, true)));
        revision.record((1, true));
        revision.invalidate();
        assert!(revision.needs_update((1, true)));
    }

    #[::core::prelude::v1::test]
    fn firmware_selection_retries_without_bypassing_explicit_path() {
        let dir = std::env::temp_dir().join(format!("nihos-selection-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let fallback = dir.join("fixture.elf");
        let explicit = dir.join("explicit.elf");
        let bundled = dir.join("nihos-native.elf");
        std::fs::write(&fallback, []).unwrap();
        assert_eq!(
            select_firmware(Some(explicit.clone()), Some(&dir), &[fallback.clone()]),
            Some(explicit)
        );
        assert_eq!(
            select_firmware(None, Some(&dir), &[fallback.clone()]),
            Some(fallback)
        );
        std::fs::write(&bundled, []).unwrap();
        assert_eq!(select_firmware(None, Some(&dir), &[]), Some(bundled));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[::core::prelude::v1::test]
    fn reset_recovers_stopped_guest_but_preserves_user_pause() {
        let mut image = vec![0u8; 88];
        image[..6].copy_from_slice(b"\x7fELF\x01\x01");
        image[16..18].copy_from_slice(&2u16.to_le_bytes());
        image[18..20].copy_from_slice(&243u16.to_le_bytes());
        image[24..28].copy_from_slice(&emu::bus::SRAM_BASE.to_le_bytes());
        image[28..32].copy_from_slice(&52u32.to_le_bytes());
        image[42..44].copy_from_slice(&32u16.to_le_bytes());
        image[44..46].copy_from_slice(&1u16.to_le_bytes());
        image[52..56].copy_from_slice(&1u32.to_le_bytes());
        image[56..60].copy_from_slice(&84u32.to_le_bytes());
        image[60..64].copy_from_slice(&emu::bus::SRAM_BASE.to_le_bytes());
        image[68..72].copy_from_slice(&4u32.to_le_bytes());
        image[72..76].copy_from_slice(&4u32.to_le_bytes());
        image[84..88].copy_from_slice(&0xffff_ffffu32.to_le_bytes());
        let path = std::env::temp_dir().join(format!("nihos-reset-{}.elf", std::process::id()));
        std::fs::write(&path, image).unwrap();
        let mut emu = emu::Emulator::new(&path, None::<&std::path::Path>).unwrap();
        emu.step_frame(1);
        assert!(emu.fault().is_some() && emu.paused);
        reset_emulator(&mut emu, true).unwrap();
        assert!(emu.fault().is_none() && !emu.paused);
        emu.paused = true;
        reset_emulator(&mut emu, false).unwrap();
        assert!(emu.paused);
        std::fs::remove_file(&path).unwrap();
        assert!(reset_emulator(&mut emu, true).is_err());
        assert!(emu.paused);
    }

    #[::core::prelude::v1::test]
    fn long_diagnostic_fits_retina_label_renderer() {
        let text = format!("{}🙂more", "x".repeat(124));
        let bounded = bounded_error_text(&text);
        assert!(bounded.len() <= 128);
        assert!(bounded.ends_with("..."));
        assert_eq!(bounded_error_text("short"), "short");
        let mut core = Core::new();
        let _image = label(
            &mut core,
            &bounded,
            [error_label_width(1500., 2.), 48., 16.],
            2.,
            [0xffa8a8, 0x101216],
            true,
        );
    }

    #[::core::prelude::v1::test]
    fn touch_mapping_accounts_for_visible_error_message() {
        let viewport = size(px(1312.), px(800.));
        let (width, height, left, top) = screen_geometry(viewport, false, true);
        assert!(width < 1280.);
        assert_eq!(
            touch_coordinates(point(px(left + 0.1), px(top + 0.1)), viewport, false, true),
            Some((0, 1279))
        );
        assert_eq!(
            touch_coordinates(
                point(px(left + 2.), px(top + height + 1.)),
                viewport,
                false,
                true
            ),
            None
        );
    }

    #[::core::prelude::v1::test]
    fn touch_maps_display_rotation_to_physical_panel() {
        let viewport = size(px(1312.), px(800.));
        assert_eq!(
            touch_coordinates(point(px(16.), px(64.)), viewport, false, false),
            Some((0, 1279))
        );
        assert_eq!(
            touch_coordinates(point(px(1295.), px(783.)), viewport, false, false),
            Some((719, 0))
        );
        assert_eq!(
            touch_coordinates(point(px(15.), px(64.)), viewport, false, false),
            None
        );
        let viewport = size(px(752.), px(1360.));
        assert_eq!(
            touch_coordinates(point(px(16.), px(64.)), viewport, true, false),
            Some((0, 0))
        );
        assert_eq!(
            touch_coordinates(point(px(735.), px(1343.)), viewport, true, false),
            Some((719, 1279))
        );
    }
    #[::core::prelude::v1::test]
    fn portrait_rotates_counterclockwise_without_losing_pixels() {
        let (w, h) = (emu::bus::FB_WIDTH, emu::bus::FB_HEIGHT);
        let mut pixels = vec![0; w * h * 4];
        pixels[..4].copy_from_slice(&[1, 2, 3, 4]);
        pixels[(w * h - 1) * 4..].copy_from_slice(&[5, 6, 7, 8]);
        let (rotated, rw, rh) = orient_frame(pixels, true);
        assert_eq!((rw, rh), (h as u32, w as u32));
        assert_eq!(&rotated[(h - 1) * 4..h * 4], &[5, 6, 7, 8]);
        assert_eq!(
            &rotated[((w - 1) * h) * 4..((w - 1) * h + 1) * 4],
            &[1, 2, 3, 4]
        );
    }
}
