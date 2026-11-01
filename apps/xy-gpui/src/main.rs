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
    emu_mode: bool,
    emu_fit: bool,
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

        // Try initializing native emulator if firmware ELF exists
        let elf_candidates = [
            "build/native-emulator/nihos-native.elf",
            "../../build/native-emulator/nihos-native.elf",
            "build/test-native-elf/nihos-native.elf",
            "../../build/test-native-elf/nihos-native.elf",
            "build/native-device/nihos-native.elf",
            "../../build/native-device/nihos-native.elf",
        ];
        let dict_candidates = [
            "build/dict/jisyo_l_nfst.bin",
            "../../build/dict/jisyo_l_nfst.bin",
            "src/xy/fixtures/jisyo_s_nfst.bin",
            "../../src/xy/fixtures/jisyo_s_nfst.bin",
        ];
        let mut emulator = None;
        let mut emu_image = None;
        let found_elf = elf_candidates
            .iter()
            .find(|p| std::path::Path::new(p).exists());
        let found_dict = dict_candidates
            .iter()
            .find(|p| std::path::Path::new(p).exists());
        if let Some(mut emu) = found_elf.and_then(|p| emu::Emulator::new(p, found_dict).ok()) {
            // Pre-run 1,000,000 instructions to initialize hardware
            emu.step_frame(1_000_000);
            let mut bgra = vec![0u8; emu::bus::FB_WIDTH * emu::bus::FB_HEIGHT * 4];
            emu.render_to_bgra(&mut bgra);
            emu_image = Some(frame(
                bgra,
                emu::bus::FB_WIDTH as u32,
                emu::bus::FB_HEIGHT as u32,
            ));
            emulator = Some(emu);
        }

        let emu_mode = emulator.is_some();
        if emu_mode {
            window.set_window_title("nihOS - M5Stack Tab5 Emulator");
        } else {
            window.set_window_title("xy - GPUI");
        }
        cx.observe_window_activation(window, |this, window, cx| {
            if !window.is_window_active() {
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
            emu_mode,
            emu_fit: true,
        }
    }
    fn now(&self) -> u64 {
        self.started.elapsed().as_micros().min(u64::MAX as u128) as u64
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
        if let Some(emu) = &mut self.emulator {
            emu.step_frame(500_000);
            let mut bgra = vec![0u8; emu::bus::FB_WIDTH * emu::bus::FB_HEIGHT * 4];
            emu.render_to_bgra(&mut bgra);
            let next = frame(bgra, emu::bus::FB_WIDTH as u32, emu::bus::FB_HEIGHT as u32);
            if let Some(old) = self.emu_image.replace(next) {
                retire(old, window);
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
        if self.tick_pending
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
    fn key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let stroke = &event.keystroke;
        if stroke.modifiers.platform && stroke.key == "q" {
            cx.quit();
            return;
        }
        if self.emu_mode {
            if let Some(emu) = &mut self.emulator {
                match stroke.key.as_str() {
                    "space" => emu.send_key(b' '),
                    "enter" => emu.send_key(b'\r'),
                    "backspace" => emu.send_key(8),
                    "escape" => emu.send_key(0x1b),
                    "tab" => emu.send_key(b'\t'),
                    "left" => emu.send_key(0x02),
                    "right" => emu.send_key(0x06),
                    "up" => emu.send_key(0x10),
                    "down" => emu.send_key(0x0e),
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
}
impl Labels {
    fn new(core: &mut Core, scale: f32) -> Self {
        let bg = [0x1c2733, 0xf4f6f8];
        Self {
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
impl Render for Workspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.schedule(window, cx);

        if self.emu_mode {
            let emu = self.emulator.as_ref();
            let is_paused = emu.is_some_and(|e| e.paused);
            let mips = emu.map_or(0.0, |e| e.mips);
            let (screen_w, screen_h) = if self.emu_fit {
                (1024., 576.)
            } else {
                (1280., 720.)
            };

            return div()
                .track_focus(&self.focus)
                .on_key_down(cx.listener(Self::key_down))
                .on_key_up(cx.listener(Self::key_up))
                .size_full()
                .flex()
                .flex_col()
                .bg(rgb(0x0e1015))
                .text_color(rgb(0xe4e4e7))
                .child(
                    // Minimalist Top Toolbar
                    div()
                        .flex()
                        .h(px(42.))
                        .px_4()
                        .items_center()
                        .justify_between()
                        .bg(rgb(0x16181f))
                        .border_b_1()
                        .border_color(rgb(0x262933))
                        // Left: Machine Brand & Status Badge
                        .child(
                            div()
                                .flex()
                                .gap_3()
                                .items_center()
                                .child(
                                    div()
                                        .flex()
                                        .items_center()
                                        .gap_2()
                                        .child(
                                            div()
                                                .font_weight(FontWeight::BOLD)
                                                .text_size(px(14.))
                                                .text_color(rgb(0xffffff))
                                                .child("nihOS"),
                                        )
                                        .child(
                                            div()
                                                .text_size(px(12.))
                                                .text_color(rgb(0x71717a))
                                                .child("ESP32-P4"),
                                        ),
                                )
                                .child(
                                    div()
                                        .flex()
                                        .items_center()
                                        .gap_1p5()
                                        .px_2()
                                        .py_0p5()
                                        .rounded_md()
                                        .bg(if is_paused {
                                            rgb(0x3f3f46)
                                        } else {
                                            rgb(0x143a22)
                                        })
                                        .child(div().size(px(6.)).rounded_full().bg(if is_paused {
                                            rgb(0xeab308)
                                        } else {
                                            rgb(0x22c55e)
                                        }))
                                        .child(
                                            div()
                                                .text_size(px(11.))
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(if is_paused {
                                                    rgb(0xfde047)
                                                } else {
                                                    rgb(0x4ade80)
                                                })
                                                .child(if is_paused {
                                                    "PAUSED".to_string()
                                                } else {
                                                    format!("{:.1} MIPS", mips)
                                                }),
                                        ),
                                )
                                .child(
                                    div()
                                        .text_size(px(11.))
                                        .text_color(rgb(0x71717a))
                                        .child("32MB PSRAM • XIP NFST"),
                                ),
                        )
                        // Right: Minimal Controls
                        .child(
                            div()
                                .flex()
                                .gap_2()
                                .items_center()
                                .child(
                                    // Pause / Resume Button
                                    div()
                                        .id("emu-pause-btn")
                                        .cursor_pointer()
                                        .px_2p5()
                                        .py_1()
                                        .rounded_md()
                                        .bg(rgb(0x27272a))
                                        .hover(|s| s.bg(rgb(0x3f3f46)))
                                        .text_size(px(12.))
                                        .on_click(cx.listener(|this, _, _window, cx| {
                                            if let Some(emu) = &mut this.emulator {
                                                emu.paused = !emu.paused;
                                            }
                                            cx.notify();
                                        }))
                                        .child(if is_paused {
                                            "▶ Resume"
                                        } else {
                                            "❚❚ Pause"
                                        }),
                                )
                                .child(
                                    // Step Button (single frame)
                                    div()
                                        .id("emu-step-btn")
                                        .cursor_pointer()
                                        .px_2p5()
                                        .py_1()
                                        .rounded_md()
                                        .bg(rgb(0x27272a))
                                        .hover(|s| s.bg(rgb(0x3f3f46)))
                                        .text_size(px(12.))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            let was_paused =
                                                this.emulator.as_ref().is_some_and(|e| e.paused);
                                            if let Some(emu) = &mut this.emulator {
                                                emu.paused = false;
                                            }
                                            this.refresh_emulator(window);
                                            if let Some(emu) = &mut this.emulator {
                                                emu.paused = was_paused;
                                            }
                                            cx.notify();
                                        }))
                                        .child("⏭ Step"),
                                )
                                .child(
                                    // Reset Button
                                    div()
                                        .id("emu-reset-btn")
                                        .cursor_pointer()
                                        .px_2p5()
                                        .py_1()
                                        .rounded_md()
                                        .bg(rgb(0x27272a))
                                        .hover(|s| s.bg(rgb(0x3f3f46)))
                                        .text_size(px(12.))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            if let Some(emu) = &mut this.emulator {
                                                let _ = emu.reset();
                                                emu.step_frame(1_000_000);
                                            }
                                            this.refresh_emulator(window);
                                            cx.notify();
                                        }))
                                        .child("↻ Reset"),
                                )
                                .child(
                                    // Fit / 1x Scale toggle
                                    div()
                                        .id("emu-scale-btn")
                                        .cursor_pointer()
                                        .px_2p5()
                                        .py_1()
                                        .rounded_md()
                                        .bg(rgb(0x27272a))
                                        .hover(|s| s.bg(rgb(0x3f3f46)))
                                        .text_size(px(12.))
                                        .on_click(cx.listener(|this, _, _window, cx| {
                                            this.emu_fit = !this.emu_fit;
                                            cx.notify();
                                        }))
                                        .child(if self.emu_fit { "⛶ 1x" } else { "⛶ Fit" }),
                                )
                                .child(
                                    // Toggle to original xy workspace
                                    div()
                                        .id("emu-workspace-btn")
                                        .cursor_pointer()
                                        .px_2p5()
                                        .py_1()
                                        .rounded_md()
                                        .bg(rgb(0x1e3a5f))
                                        .hover(|s| s.bg(rgb(0x2563eb)))
                                        .text_size(px(12.))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.emu_mode = false;
                                            window.set_window_title("xy - GPUI");
                                            cx.notify();
                                        }))
                                        .child("xy IDE ↗"),
                                ),
                        ),
                )
                // Center Screen Display
                .child(
                    div()
                        .flex_1()
                        .flex()
                        .items_center()
                        .justify_center()
                        .p_4()
                        .child(if let Some(emu_img) = &self.emu_image {
                            div()
                                .flex()
                                .flex_col()
                                .items_center()
                                .gap_3()
                                .child(
                                    // Bezel around display
                                    div()
                                        .border_2()
                                        .border_color(rgb(0x27272a))
                                        .rounded_lg()
                                        .overflow_hidden()
                                        .shadow_lg()
                                        .bg(rgb(0x000000))
                                        .child(shown(emu_img, screen_w, screen_h)),
                                )
                                .child(
                                    // M5 Tab5 Bottom Buttons (A, B, C)
                                    div()
                                        .flex()
                                        .gap_4()
                                        .items_center()
                                        .child(
                                            div()
                                                .id("btn-m5-a")
                                                .px_4()
                                                .py_1()
                                                .rounded_md()
                                                .bg(rgb(0x1a1d24))
                                                .border_1()
                                                .border_color(rgb(0x27272a))
                                                .text_color(rgb(0x71717a))
                                                .text_size(px(11.))
                                                .cursor_pointer()
                                                .hover(|s| {
                                                    s.bg(rgb(0x27272a)).text_color(rgb(0xffffff))
                                                })
                                                .on_click(cx.listener(|this, _, _, _| {
                                                    if let Some(emu) = &mut this.emulator {
                                                        emu.send_key(b'a');
                                                    }
                                                }))
                                                .child("Button A"),
                                        )
                                        .child(
                                            div()
                                                .id("btn-m5-b")
                                                .px_4()
                                                .py_1()
                                                .rounded_md()
                                                .bg(rgb(0x1a1d24))
                                                .border_1()
                                                .border_color(rgb(0x27272a))
                                                .text_color(rgb(0x71717a))
                                                .text_size(px(11.))
                                                .cursor_pointer()
                                                .hover(|s| {
                                                    s.bg(rgb(0x27272a)).text_color(rgb(0xffffff))
                                                })
                                                .on_click(cx.listener(|this, _, _, _| {
                                                    if let Some(emu) = &mut this.emulator {
                                                        emu.send_key(b'b');
                                                    }
                                                }))
                                                .child("Button B"),
                                        )
                                        .child(
                                            div()
                                                .id("btn-m5-c")
                                                .px_4()
                                                .py_1()
                                                .rounded_md()
                                                .bg(rgb(0x1a1d24))
                                                .border_1()
                                                .border_color(rgb(0x27272a))
                                                .text_color(rgb(0x71717a))
                                                .text_size(px(11.))
                                                .cursor_pointer()
                                                .hover(|s| {
                                                    s.bg(rgb(0x27272a)).text_color(rgb(0xffffff))
                                                })
                                                .on_click(cx.listener(|this, _, _, _| {
                                                    if let Some(emu) = &mut this.emulator {
                                                        emu.send_key(b'c');
                                                    }
                                                }))
                                                .child("Button C"),
                                        ),
                                )
                        } else {
                            div()
                                .flex()
                                .flex_col()
                                .items_center()
                                .gap_2()
                                .text_color(rgb(0x71717a))
                                .child("Firmware ELF not loaded")
                                .child("Place nihos-native.elf into build/native-emulator/ to run")
                        }),
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
