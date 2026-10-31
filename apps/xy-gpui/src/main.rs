mod core;
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
    tick_pending: bool,
    frames: u64,
    labels: Labels,
    status: Arc<RenderImage>,
    scale: f32,
    status_key: (u32, u32, bool),
}
impl Workspace {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut core = Core::new();
        let scale = window.scale_factor().min(2.);
        let width = (PANE_W * scale).round().clamp(240., 1280.) as u32;
        let height = (PANE_H * scale).round().clamp(180., 720.) as u32;
        window.set_window_title("xy - GPUI");
        let focus = cx.focus_handle();
        window.focus(&focus);
        let editor = frame(core.bgra(true, width, height), width, height);
        let graph = frame(core.bgra(false, width, height), width, height);
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
            tick_pending: false,
            frames: 1,
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
    }
    fn press(&mut self, key: Key, window: &mut Window, cx: &mut Context<Self>) {
        self.core.press(key, self.now());
        self.refresh_graph(window);
        cx.notify();
    }
    fn schedule(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.tick_pending || self.core.state().paused != 0 || self.core.state().stopped != 0 {
            return;
        }
        self.tick_pending = true;
        cx.on_next_frame(window, |this, window, cx| {
            this.tick_pending = false;
            if this.core.state().stopped != 0 {
                return;
            }
            if this.core.tick(this.now()) {
                this.refresh_graph(window);
                cx.notify();
            }
            // request_animation_frame needs GPUI's render phase. Notify here;
            // render() schedules the next frame with the proper view context.
            if this.core.state().paused == 0 {
                cx.notify();
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
                "Click a pane or press Tab to switch focus.",
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
