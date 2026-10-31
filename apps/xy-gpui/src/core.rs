//! One synchronous foreground owner of the shared Zig host instance.
use std::sync::{Mutex, MutexGuard};
static OWNER: Mutex<()> = Mutex::new(());
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct State {
    pub ticks: u64,
    pub phase: u64,
    pub generation: u64,
    pub dropped_us: u64,
    pub paused: u32,
    pub speed: u32,
    pub held: u32,
}
#[derive(Clone, Copy)]
pub enum Key {
    Pause,
    Slower,
    Faster,
    Reset,
}
unsafe extern "C" {
    fn xy_animation_init() -> bool;
    fn xy_animation_tick(now_us: u64) -> bool;
    fn xy_animation_key(key: u8, down: bool, now_us: u64) -> bool;
    fn xy_animation_focus_lost(now_us: u64);
    fn xy_animation_state(out: *mut State);
    fn xy_animation_render_rgb565(out: *mut u8, capacity: usize, w: u32, h: u32) -> bool;
    fn xy_animation_render_bgra8(out: *mut u8, capacity: usize, w: u32, h: u32) -> bool;
    fn xy_editor_render_bgra8(out: *mut u8, capacity: usize, w: u32, h: u32) -> bool;
    fn xy_editor_insert(text: *const u8, len: u32) -> bool;
    fn xy_editor_key(key: u8) -> bool;
    fn xy_label_render_bgra8(
        out: *mut u8,
        cap: usize,
        text: *const u8,
        len: u32,
        w: u32,
        h: u32,
        size: u8,
        fg: u32,
        bg: u32,
        centered: bool,
    ) -> bool;
}
pub struct Core {
    _owner: MutexGuard<'static, ()>,
}
impl Core {
    pub fn new() -> Self {
        let owner = OWNER.lock().expect("single foreground core owner");
        assert!(
            unsafe { xy_animation_init() },
            "initialize shared xy renderer"
        );
        Self { _owner: owner }
    }
    pub fn state(&self) -> State {
        let mut out = State::default();
        unsafe { xy_animation_state(&mut out) };
        out
    }
    pub fn tick(&mut self, now: u64) -> bool {
        unsafe { xy_animation_tick(now) }
    }
    pub fn key(&mut self, key: Key, down: bool, now: u64) {
        assert!(unsafe { xy_animation_key(key as u8, down, now) });
    }
    pub fn press(&mut self, key: Key, now: u64) {
        self.key(key, true, now);
        self.key(key, false, now);
    }
    pub fn focus_lost(&mut self, now: u64) {
        unsafe { xy_animation_focus_lost(now) }
    }
    pub fn editor_insert(&mut self, text: &str) -> bool {
        unsafe {
            xy_editor_insert(
                text.as_ptr(),
                text.len().try_into().expect("bounded key text"),
            )
        }
    }
    pub fn editor_key(&mut self, key: u8) -> bool {
        unsafe { xy_editor_key(key) }
    }
    pub fn bgra(&mut self, editor: bool, w: u32, h: u32) -> Vec<u8> {
        assert!((240..=1280).contains(&w) && (180..=720).contains(&h));
        let mut bytes = vec![0; w as usize * h as usize * 4];
        let ok = unsafe {
            if editor {
                xy_editor_render_bgra8(bytes.as_mut_ptr(), bytes.len(), w, h)
            } else {
                xy_animation_render_bgra8(bytes.as_mut_ptr(), bytes.len(), w, h)
            }
        };
        assert!(ok, "shared frame rendering failed");
        bytes
    }
    pub fn rgb565(&mut self, w: u32, h: u32) -> Vec<u8> {
        let mut bytes = vec![0; w as usize * h as usize * 2];
        assert!(unsafe { xy_animation_render_rgb565(bytes.as_mut_ptr(), bytes.len(), w, h) });
        bytes
    }
    pub fn label(
        &mut self,
        text: &str,
        dimensions: [u32; 3],
        colors: [u32; 2],
        centered: bool,
    ) -> Vec<u8> {
        let [w, h, size] = dimensions;
        let mut bytes = vec![0; w as usize * h as usize * 4];
        assert!(
            unsafe {
                xy_label_render_bgra8(
                    bytes.as_mut_ptr(),
                    bytes.len(),
                    text.as_ptr(),
                    text.len() as u32,
                    w,
                    h,
                    size as u8,
                    colors[0],
                    colors[1],
                    centered,
                )
            },
            "shared label rendering failed: {text}"
        );
        bytes
    }
}
pub fn check_and_snapshot(directory: &std::path::Path) {
    std::fs::create_dir_all(directory).unwrap();
    let mut core = Core::new();
    let (w, h) = (1024, 720);
    core.tick(0);
    let first = core.bgra(false, w, h);
    save(directory, "initial", &first, w, h);
    core.tick(66_668);
    let moved = core.bgra(false, w, h);
    assert_ne!(first, moved, "curve must move");
    save(directory, "moving", &moved, w, h);
    core.press(Key::Pause, 66_668);
    let ticks = core.state().ticks;
    let generation = core.state().generation;
    assert!(!core.tick(10_000_000));
    assert_eq!(core.state().generation, generation);
    assert_eq!(moved, core.bgra(false, w, h), "pause must preserve pixels");
    core.press(Key::Pause, 10_000_000);
    core.tick(10_016_667);
    assert_eq!(core.state().ticks, ticks + 1, "resume must not catch up");
    core.key(Key::Faster, true, 10_016_667);
    let speed = core.state().speed;
    core.key(Key::Faster, true, 10_016_667);
    assert_eq!(core.state().speed, speed, "held down must not repeat");
    core.focus_lost(10_016_667);
    assert_eq!(core.state().held, 0);
    assert_eq!(core.state().paused, 1);
    let rgb = core.rgb565(w, h);
    let bgra = core.bgra(false, w, h);
    for (packed, pixel) in rgb
        .as_chunks::<2>()
        .0
        .iter()
        .zip(bgra.as_chunks::<4>().0.iter())
    {
        let c = u16::from_le_bytes([packed[0], packed[1]]);
        let (r, g, b) = (
            ((c >> 11) & 31) as u8,
            ((c >> 5) & 63) as u8,
            (c & 31) as u8,
        );
        assert_eq!(
            pixel,
            &[
                (b << 3) | (b >> 2),
                (g << 2) | (g >> 4),
                (r << 3) | (r >> 2),
                255
            ]
        );
    }
    let editor_before = core.bgra(true, w, h);
    assert!(core.editor_insert("abc"));
    assert_ne!(editor_before, core.bgra(true, w, h));
    assert!(core.editor_key(3));
    assert_eq!(
        editor_before,
        core.bgra(true, w, h),
        "editor undo restores exact pixels"
    );
    save(directory, "editor", &editor_before, w, h);
    let label = core.label("Pause", [160, 80, 32], [0xffffff, 0x0755aa], true);
    assert!(
        label
            .as_chunks::<4>()
            .0
            .iter()
            .any(|p| p[0] > 220 && p[1] > 220 && p[2] > 220),
        "label must contain visible text"
    );
    save(directory, "label", &label, 160, 80);
    let mut guard = [0xa5u8; 64];
    assert!(!unsafe { xy_animation_render_bgra8(guard.as_mut_ptr(), guard.len(), w, h) });
    assert!(!unsafe { xy_animation_render_bgra8(guard.as_mut_ptr(), guard.len(), 1, 1) });
    assert!(guard.iter().all(|b| *b == 0xa5));
    std::fs::write(directory.join("result.json"), "{\"passed\":true,\"canonical_pixels_compared\":737280,\"animation\":true,\"pause_resume\":true,\"held_and_focus\":true,\"editor_undo_pixels\":true,\"invalid_buffer_rejected\":true,\"gpui_window_tested\":false,\"physical_device_tested\":false}\n").unwrap();
    println!(
        "Shared Zig animation/frame/keyboard checks passed; GPUI window not exercised by this check"
    );
}
fn save(directory: &std::path::Path, name: &str, bgra: &[u8], w: u32, h: u32) {
    let mut rgba = bgra.to_vec();
    for pixel in rgba.as_chunks_mut::<4>().0 {
        pixel.swap(0, 2);
    }
    image::save_buffer(
        directory.join(format!("{name}.png")),
        &rgba,
        w,
        h,
        image::ColorType::Rgba8,
    )
    .unwrap();
}
