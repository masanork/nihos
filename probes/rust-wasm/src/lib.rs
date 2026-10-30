#![no_std]
use core::panic::PanicInfo;
#[path = "../../rust-app/src/app.rs"]
mod app;

#[unsafe(no_mangle)]
pub extern "C" fn nih_rust_app_frame(selected: u32) -> i32 {
    if selected > 1 {
        return -1;
    }
    app::draw(&mut nihos_app::Wasm, selected == 1)
        .err()
        .unwrap_or(0)
}
// Malicious-module fixtures used by the embedding tests, not application API.
#[link(wasm_import_module = "nihos")]
unsafe extern "C" {
    fn nih_app_text(x: i32, y: i32, bytes: u32, len: u32, rgb: u32) -> i32;
}
#[unsafe(no_mangle)]
pub extern "C" fn nih_probe_raw_text(offset: u32, length: u32) -> i32 {
    // SAFETY: the host must reject invalid linear memory ranges.
    unsafe { nih_app_text(8, 8, offset, length, 0xffffff) }
}
#[unsafe(no_mangle)]
pub extern "C" fn nih_probe_bad_text() -> i32 {
    static BAD: [u8; 1] = [0xff];
    // SAFETY: BAD is valid linear memory; the host rejects unsupported text.
    unsafe { nih_app_text(8, 8, BAD.as_ptr() as u32, 1, 0xffffff) }
}
#[unsafe(no_mangle)]
pub extern "C" fn nih_probe_spin() {
    loop {
        core::hint::spin_loop();
    }
}
#[panic_handler]
fn panic(_: &PanicInfo<'_>) -> ! {
    loop {
        core::hint::spin_loop();
    }
}

/// Test-only probe for the module's configured memory maximum.
#[unsafe(no_mangle)]
pub extern "C" fn nih_probe_grow(pages: u32) -> u32 {
    core::arch::wasm32::memory_grow::<0>(pages as usize) as u32
}

#[inline(never)]
fn nested(depth: u32) -> u32 {
    if depth == 0 {
        1
    } else {
        core::hint::black_box(nested(depth - 1)) + 1
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn nih_probe_nested(depth: u32) -> u32 {
    nested(depth)
}
#[unsafe(no_mangle)]
pub extern "C" fn nih_probe_wide(value: u64) -> u64 {
    core::hint::black_box(value) ^ 0x0123_4567_89ab_cdef
}
