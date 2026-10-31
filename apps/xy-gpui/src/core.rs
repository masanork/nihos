//! One synchronous foreground owner of the shared Zig host instance.
use std::sync::{Mutex, MutexGuard};
static OWNER: Mutex<()> = Mutex::new(());
const ABI_VERSION: u32 = 1;
const CLOSED: i32 = -3;
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct State {
    pub size: u32,
    pub abi_version: u32,
    pub ticks: u64,
    pub phase: u64,
    pub generation: u64,
    pub dropped_us: u64,
    pub paused: u32,
    pub speed: u32,
    pub held: u32,
    pub pressed: u32,
    pub released: u32,
    pub stopped: u32,
    pub focused: u32,
    pub reserved: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct Info {
    size: u32,
    abi_version: u32,
    min_width: u32,
    min_height: u32,
    max_width: u32,
    max_height: u32,
    stride_limit: u32,
    frame_bytes_limit: u32,
    format_mask: u32,
    key_count: u32,
    step_us: u32,
    catch_up_steps: u32,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Event {
    size: u32,
    abi_version: u32,
    monotonic_us: u64,
    kind: u32,
    code: u32,
    value: u32,
    reserved: u32,
}
impl Event {
    fn new(kind: u32, code: u32, monotonic_us: u64) -> Self {
        Self {
            size: size_of::<Self>() as u32,
            abi_version: ABI_VERSION,
            monotonic_us,
            kind,
            code,
            value: 0,
            reserved: 0,
        }
    }
}
#[repr(C)]
#[derive(Clone, Copy)]
struct FrameRequest {
    size: u32,
    abi_version: u32,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    pane: u32,
    reserved: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct FrameInfo {
    size: u32,
    abi_version: u32,
    generation: u64,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    byte_length: u32,
    reserved: u32,
}
#[derive(Clone, Copy)]
pub enum Key {
    Pause,
    Slower,
    Faster,
    Reset,
}
unsafe extern "C" {
    fn xy_app_query(version: u32, out: *mut Info, size: u32) -> i32;
    fn xy_app_open(version: u32) -> i32;
    fn xy_app_event(event: *const Event) -> i32;
    fn xy_app_state(version: u32, out: *mut State, size: u32) -> i32;
    fn xy_app_frame(
        request: *const FrameRequest,
        out: *mut u8,
        capacity: usize,
        metadata: *mut FrameInfo,
        metadata_size: u32,
    ) -> i32;
    fn xy_editor_insert(text: *const u8, len: u32) -> bool;
    fn xy_editor_key(key: u8) -> bool;
    fn xy_app_scheme_eval(source: *const u8, len: u32, out: *mut u8, cap: u32, now: u64) -> i32;
    fn xy_app_scheme_eval_buffer(out: *mut u8, cap: u32, now: u64) -> i32;
    fn xy_app_scheme_error(out: *mut u8, cap: u32) -> u32;
    fn xy_app_scheme_registered() -> bool;
    fn xy_app_editor_generation() -> u64;
    fn xy_host_buffer_copy(out: *mut u8, capacity: u32) -> i32;
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
        assert_eq!(size_of::<Info>(), 48);
        assert_eq!(size_of::<State>(), 72);
        assert_eq!(size_of::<Event>(), 32);
        assert_eq!(size_of::<FrameRequest>(), 32);
        assert_eq!(size_of::<FrameInfo>(), 40);
        let mut info = Info::default();
        assert_eq!(
            unsafe { xy_app_query(ABI_VERSION, &mut info, size_of::<Info>() as u32) },
            0
        );
        assert_eq!((info.size, info.abi_version), (48, ABI_VERSION));
        assert_eq!(
            (info.step_us, info.catch_up_steps, info.key_count),
            (16_667, 4, 32)
        );
        assert_eq!(
            unsafe { xy_app_open(ABI_VERSION) },
            0,
            "initialize shared app"
        );
        Self { _owner: owner }
    }
    pub fn state(&self) -> State {
        let mut out = State::default();
        assert_eq!(
            unsafe { xy_app_state(ABI_VERSION, &mut out, size_of::<State>() as u32) },
            0
        );
        out
    }
    fn event(&mut self, kind: u32, code: u32, now: u64) -> i32 {
        unsafe { xy_app_event(&Event::new(kind, code, now)) }
    }
    pub fn tick(&mut self, now: u64) -> bool {
        let previous = self.state().generation;
        assert!(self.event(0, 0, now) >= 0);
        self.state().generation != previous
    }
    pub fn key(&mut self, key: Key, down: bool, now: u64) {
        let result = self.event(if down { 1 } else { 2 }, key as u32, now);
        assert!(
            result >= 0 || result == -5,
            "only inactive input may be ignored"
        );
    }
    pub fn press(&mut self, key: Key, now: u64) {
        self.key(key, true, now);
        self.key(key, false, now);
    }
    pub fn focus_lost(&mut self, now: u64) {
        assert!(self.event(3, 0, now) >= 0);
    }
    pub fn focus_gained(&mut self, now: u64) {
        assert!(self.event(4, 0, now) >= 0);
    }
    pub fn cancel(&mut self, now: u64) {
        assert!(self.event(5, 0, now) >= 0);
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
    pub fn eval(&mut self, source: &str, now: u64) -> Result<String, String> {
        let mut out = [0; 256];
        let length = unsafe {
            xy_app_scheme_eval(
                source.as_ptr(),
                source.len().try_into().expect("bounded Scheme source"),
                out.as_mut_ptr(),
                256,
                now,
            )
        };
        self.eval_result(length, &out)
    }
    pub fn eval_buffer(&mut self, now: u64) -> Result<String, String> {
        let mut out = [0; 256];
        let length = unsafe { xy_app_scheme_eval_buffer(out.as_mut_ptr(), 256, now) };
        self.eval_result(length, &out)
    }
    fn eval_result(&self, length: i32, out: &[u8]) -> Result<String, String> {
        if length < 0 {
            let mut error = [0; 128];
            let size = unsafe { xy_app_scheme_error(error.as_mut_ptr(), 128) };
            Err(String::from_utf8_lossy(&error[..size as usize]).into_owned())
        } else {
            Ok(String::from_utf8_lossy(&out[..length as usize]).into_owned())
        }
    }
    pub fn registered(&self) -> bool {
        unsafe { xy_app_scheme_registered() }
    }
    pub fn editor_generation(&self) -> u64 {
        unsafe { xy_app_editor_generation() }
    }
    fn render(&mut self, editor: bool, w: u32, h: u32, format: u32) -> Vec<u8> {
        assert!((240..=1280).contains(&w) && (180..=720).contains(&h));
        let stride = w * if format == 1 { 2 } else { 4 };
        let request = FrameRequest {
            size: size_of::<FrameRequest>() as u32,
            abi_version: ABI_VERSION,
            width: w,
            height: h,
            stride,
            format,
            pane: u32::from(editor),
            reserved: 0,
        };
        let mut bytes = vec![0; stride as usize * h as usize];
        let mut metadata = FrameInfo::default();
        assert_eq!(
            unsafe {
                xy_app_frame(
                    &request,
                    bytes.as_mut_ptr(),
                    bytes.len(),
                    &mut metadata,
                    size_of::<FrameInfo>() as u32,
                )
            },
            0,
            "shared frame rendering failed"
        );
        assert_eq!(metadata.size, size_of::<FrameInfo>() as u32);
        assert_eq!(metadata.abi_version, ABI_VERSION);
        assert_eq!(
            (
                metadata.width,
                metadata.height,
                metadata.stride,
                metadata.format,
                metadata.byte_length
            ),
            (w, h, stride, format, bytes.len() as u32)
        );
        bytes
    }
    pub fn bgra(&mut self, editor: bool, w: u32, h: u32) -> Vec<u8> {
        self.render(editor, w, h, 2)
    }
    pub fn rgb565(&mut self, w: u32, h: u32) -> Vec<u8> {
        self.render(false, w, h, 1)
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
impl Drop for Core {
    fn drop(&mut self) {
        // Cancel is terminal and idempotent; no borrowed callback survives.
        self.cancel(0);
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
    check_protocol(&mut core);
    check_scheme(&mut core, directory);
    std::fs::write(directory.join("result.json"), "{\"passed\":true,\"canonical_pixels_compared\":737280,\"animation\":true,\"pause_resume\":true,\"held_and_focus\":true,\"editor_undo_pixels\":true,\"invalid_buffer_rejected\":true,\"app_protocol_v1\":true,\"strided_frames\":true,\"cancel_reopen\":true,\"scheme_frames\":true,\"scheme_gc\":true,\"scheme_fault_recovery\":true,\"gpui_window_tested\":false,\"physical_device_tested\":false}\n").unwrap();
    println!(
        "Shared Zig animation/frame/keyboard checks passed; GPUI window not exercised by this check"
    );
}
fn check_protocol(core: &mut Core) {
    let mut info = Info::default();
    assert_eq!(
        unsafe { xy_app_query(99, &mut info, size_of::<Info>() as u32) },
        -2
    );
    assert_eq!(info.size, 0, "unsupported query must not write output");
    assert_eq!(unsafe { xy_app_query(ABI_VERSION, &mut info, 4) }, -1);
    assert_eq!(info.size, 0);
    assert_eq!(
        unsafe { xy_app_query(ABI_VERSION, std::ptr::null_mut(), 48) },
        -1
    );
    let before = core.state();
    assert_eq!(unsafe { xy_app_open(99) }, -2);
    for event in [
        Event {
            abi_version: 99,
            ..Event::new(0, 0, u64::MAX)
        },
        Event {
            size: 4,
            ..Event::new(0, 0, u64::MAX)
        },
        Event {
            reserved: 1,
            ..Event::new(0, 0, u64::MAX)
        },
        Event {
            value: 1,
            ..Event::new(0, 0, u64::MAX)
        },
        Event::new(99, 0, u64::MAX),
        Event::new(1, 32, u64::MAX),
        Event::new(0, 1, u64::MAX),
    ] {
        assert!(unsafe { xy_app_event(&event) } < 0);
        assert_eq!(core.state(), before, "invalid event changed state");
    }
    assert_eq!(unsafe { xy_app_event(std::ptr::null()) }, -1);
    let mut state_guard = State::default();
    assert_eq!(unsafe { xy_app_state(99, &mut state_guard, 72) }, -2);
    assert_eq!(
        unsafe { xy_app_state(ABI_VERSION, &mut state_guard, 4) },
        -1
    );
    assert_eq!(state_guard, State::default());
    let request = FrameRequest {
        size: 32,
        abi_version: ABI_VERSION,
        width: 240,
        height: 180,
        stride: 960,
        format: 2,
        pane: 0,
        reserved: 0,
    };
    let mut buffer = vec![0xa5; 960 * 180 + 16];
    let mut metadata = FrameInfo::default();
    for bad in [
        FrameRequest {
            abi_version: 99,
            ..request
        },
        FrameRequest { size: 4, ..request },
        FrameRequest {
            width: u32::MAX,
            ..request
        },
        FrameRequest {
            height: 0,
            ..request
        },
        FrameRequest {
            stride: u32::MAX,
            ..request
        },
        FrameRequest {
            stride: 959,
            ..request
        },
        FrameRequest {
            format: 99,
            ..request
        },
        FrameRequest {
            pane: 99,
            ..request
        },
        FrameRequest {
            reserved: 1,
            ..request
        },
    ] {
        assert!(
            unsafe { xy_app_frame(&bad, buffer.as_mut_ptr(), buffer.len(), &mut metadata, 40) } < 0
        );
        assert!(buffer.iter().all(|b| *b == 0xa5));
        assert_eq!(metadata, FrameInfo::default());
        assert_eq!(core.state(), before);
    }
    for (capacity, metadata_size) in [(960 * 180 - 1, 40), (buffer.len(), 4)] {
        assert_eq!(
            unsafe {
                xy_app_frame(
                    &request,
                    buffer.as_mut_ptr(),
                    capacity,
                    &mut metadata,
                    metadata_size,
                )
            },
            -1
        );
        assert!(buffer.iter().all(|b| *b == 0xa5));
        assert_eq!(metadata, FrameInfo::default());
    }
    assert_eq!(
        unsafe {
            xy_app_frame(
                &request,
                std::ptr::null_mut(),
                buffer.len(),
                &mut metadata,
                40,
            )
        },
        -1
    );
    assert_eq!(
        unsafe {
            xy_app_frame(
                &request,
                buffer.as_mut_ptr(),
                buffer.len(),
                std::ptr::null_mut(),
                40,
            )
        },
        -1
    );
    assert_eq!(
        unsafe {
            xy_app_frame(
                std::ptr::null(),
                buffer.as_mut_ptr(),
                buffer.len(),
                &mut metadata,
                40,
            )
        },
        -1
    );
    // Both panes and both pixel formats preserve stride padding and suffix.
    for pane in 0..2 {
        for format in 1..=2 {
            let row = 240 * if format == 1 { 2 } else { 4 };
            let stride = row + 13;
            let req = FrameRequest {
                pane,
                format,
                stride,
                ..request
            };
            let mut padded = vec![0xa5; stride as usize * 180 + 16];
            let tight = core.render(pane == 1, 240, 180, format);
            assert_eq!(
                unsafe { xy_app_frame(&req, padded.as_mut_ptr(), padded.len(), &mut metadata, 40) },
                0
            );
            assert_eq!(metadata.byte_length, stride * 180);
            for y in 0..180 {
                let start = y * stride as usize;
                assert_eq!(
                    &padded[start..start + row as usize],
                    &tight[y * row as usize..(y + 1) * row as usize]
                );
                assert!(
                    padded[start + row as usize..start + stride as usize]
                        .iter()
                        .all(|b| *b == 0xa5)
                );
            }
            assert!(padded[stride as usize * 180..].iter().all(|b| *b == 0xa5));
        }
    }
    assert_eq!(
        core.state(),
        before,
        "render must not tick or consume edges"
    );
    assert_eq!(core.event(1, 0, 30_000_000), -5);
    assert_eq!(core.state(), before, "inactive input must not change state");
    // The host owns every completed frame, independent of later renders.
    let retained = core.bgra(false, 240, 180);
    let saved = retained.clone();
    core.focus_gained(30_000_000);
    assert_eq!(core.state().paused, 1);
    core.press(Key::Pause, 30_000_000);
    core.tick(30_016_667);
    assert_ne!(retained, core.bgra(false, 240, 180));
    assert_eq!(retained, saved);
    assert!(core.event(1, 31, 30_016_667) >= 0);
    assert_eq!(core.state().pressed, 1 << 31);
    assert!(core.event(1, 31, 30_016_667) >= 0);
    assert_eq!(core.state().pressed, 0);
    core.cancel(u64::MAX);
    let stopped = core.state();
    assert_eq!((stopped.stopped, stopped.paused, stopped.held), (1, 1, 0));
    assert_eq!(stopped.released, 1 << 31);
    assert_eq!(core.event(0, 0, u64::MAX), CLOSED);
    assert_eq!(core.event(1, 0, u64::MAX), CLOSED);
    core.cancel(0);
    assert_eq!(stopped, core.state(), "cancel is terminal and idempotent");
    buffer.fill(0xa5);
    metadata = FrameInfo::default();
    assert_eq!(
        unsafe {
            xy_app_frame(
                &request,
                buffer.as_mut_ptr(),
                buffer.len(),
                &mut metadata,
                40,
            )
        },
        CLOSED
    );
    assert!(buffer.iter().all(|b| *b == 0xa5));
    assert_eq!(metadata, FrameInfo::default());
    assert!(!core.editor_insert("stopped"));
    assert!(!core.editor_key(4));
    assert_eq!(unsafe { xy_app_open(ABI_VERSION) }, 0);
    assert_eq!(
        (core.state().ticks, core.state().held, core.state().stopped),
        (0, 0, 0)
    );
    assert_ne!(core.bgra(false, 240, 180), retained);
    for code in 0..32 {
        assert!(core.event(1, code, 0) >= 0);
        assert_eq!(
            (core.state().held, core.state().pressed),
            (1 << code, 1 << code)
        );
        assert!(core.event(1, code, 0) >= 0);
        assert_eq!(core.state().pressed, 0);
        assert!(core.event(2, code, 0) >= 0);
        assert_eq!((core.state().held, core.state().released), (0, 1 << code));
    }
}
fn document_text() -> Vec<u8> {
    let mut bytes = vec![0; 16384];
    let length = unsafe { xy_host_buffer_copy(bytes.as_mut_ptr(), 16384) };
    assert!(length >= 0);
    bytes.truncate(length as usize);
    bytes
}
fn check_scheme(core: &mut Core, directory: &std::path::Path) {
    assert_eq!(unsafe { xy_app_open(ABI_VERSION) }, 0);
    assert!(!core.registered());
    let mut now = 0;
    core.tick(now);
    core.eval_buffer(now)
        .expect("run the editable Scheme example");
    assert!(core.registered());
    now += 16_667;
    core.tick(now);
    assert_eq!(core.eval("(plot/get #:amplitude)", now).unwrap(), "50");
    let image = core.bgra(false, 1024, 720);
    save(directory, "scheme-moving", &image, 1024, 720);
    core.eval("(plot/set! #:amplitude 0) (app/on-frame! #f)", now)
        .unwrap();
    assert!(!core.registered());
    assert_ne!(
        image,
        core.bgra(false, 1024, 720),
        "Scheme settings affect actual pixels"
    );
    core.eval("(define frames 0) (app/on-frame! (let ((n 0)) (lambda (ticks) (set! n (+ n 1)) (set! frames n))))", now).unwrap();
    for _ in 0..600 {
        now += 16_667;
        core.tick(now);
    }
    assert_eq!(
        core.eval("frames", now).unwrap(),
        "600",
        "captured state survives request GC"
    );
    core.press(Key::Pause, now);
    core.tick(now + 1_000_000);
    assert_eq!(core.eval("frames", now).unwrap(), "600");
    assert!(core.registered(), "pause retains callback");
    now += 1_000_000;
    core.eval("(app/resume!)", now).unwrap();
    let before_ticks = core.state().ticks;
    now += 1_000_000;
    core.tick(now);
    assert_eq!(core.state().ticks, before_ticks + 4);
    assert_eq!(
        core.eval("frames", now).unwrap(),
        "601",
        "one coalesced callback per accepted update"
    );
    core.eval("(app/on-frame! (lambda (t) (buffer/insert! \"x\")))", now)
        .unwrap();
    let document_before = document_text();
    let editor_generation = core.editor_generation();
    now += 16_667;
    core.tick(now);
    assert!(core.editor_generation() > editor_generation);
    let mut expected = document_before.clone();
    expected.extend_from_slice(b"x");
    assert_eq!(document_text(), expected);
    assert!(core.editor_key(3));
    assert_eq!(document_text(), document_before);
    core.eval("(define keep 7) (app/on-frame! (lambda (t) (set! keep 9) (plot/set! #:amplitude 5) (buffer/insert! \"bad\") missing))", now).unwrap();
    now += 16_667;
    core.tick(now);
    assert_eq!(core.state().paused, 1);
    assert!(!core.registered());
    assert_eq!(core.eval_result(-1, &[]).unwrap_err(), "Unbound name");
    save(
        directory,
        "scheme-error",
        &core.bgra(true, 1024, 720),
        1024,
        720,
    );
    assert_eq!(
        document_text(),
        document_before,
        "failed callback rolls back editor"
    );
    assert_eq!(
        core.eval("keep", now).unwrap(),
        "7",
        "failed callback rolls back VM"
    );
    assert_eq!(
        core.eval("(plot/get #:amplitude)", now).unwrap(),
        "0",
        "failed callback rolls back plot"
    );
    assert!(core.editor_insert("good"));
    assert!(core.editor_key(3));
    assert_eq!(document_text(), document_before);
    let work = format!(
        "(define (work) {}) (app/on-frame! (lambda (t) {})) (app/resume!)",
        "(if #t #t #t) ".repeat(12),
        "(work) ".repeat(6)
    );
    core.eval(&work, now).unwrap();
    now += 16_667;
    core.tick(now);
    assert!(!core.registered());
    assert_eq!(core.state().paused, 1);
    assert_eq!(core.eval_result(-1, &[]).unwrap_err(), "Evaluation budget");
    core.eval(
        "(app/on-frame! (lambda (t) (set! frames (+ frames 1)))) (app/resume!)",
        now,
    )
    .unwrap();
    core.eval("(app/stop!)", now).unwrap();
    let count = core.eval("frames", now).unwrap();
    now += 1_000_000;
    assert!(!core.tick(now));
    assert_eq!(core.eval("frames", now).unwrap(), count);
    assert!(!core.registered());
    core.eval_buffer(now).unwrap();
    assert!(core.registered());
    core.cancel(now);
    assert!(!core.registered());
    assert!(core.eval_buffer(now).is_err());
    assert_eq!(unsafe { xy_app_open(ABI_VERSION) }, 0);
    assert!(!core.registered(), "reopen has no stale callback");
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
