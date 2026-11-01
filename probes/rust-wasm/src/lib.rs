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

// Test-only Wasm instructions for the RV32 interpreter alignment fixture.
#[cfg(feature = "alignment-corpus")]
#[unsafe(no_mangle)]
pub extern "C" fn nih_probe_unaligned(value: u64) -> u64 {
    let mut bytes = [0u8; 24];
    // SAFETY: the eight-byte region starting at byte 1 is in bounds. The
    // unaligned operations deliberately make no alignment promise.
    unsafe {
        let slot = core::hint::black_box(bytes.as_mut_ptr().add(1)) as *mut u64;
        core::ptr::write_unaligned(slot, core::hint::black_box(value));
        core::ptr::read_unaligned(core::hint::black_box(slot))
    }
}

#[cfg(feature = "alignment-corpus")]
#[inline(never)]
fn corpus_add(value: u32) -> u32 { value.wrapping_add(7) }
#[cfg(feature = "alignment-corpus")]
#[inline(never)]
fn corpus_xor(value: u32) -> u32 { value ^ 0xa5a5_5a5a }
#[cfg(feature = "alignment-corpus")]
#[unsafe(no_mangle)]
pub extern "C" fn nih_probe_indirect(select: u32, value: u32) -> u32 {
    let function: fn(u32) -> u32 = if select & 1 == 0 { corpus_add } else { corpus_xor };
    core::hint::black_box(function)(core::hint::black_box(value))
}

#[cfg(feature = "alignment-corpus")]
#[unsafe(no_mangle)]
pub extern "C" fn nih_probe_corpus_trap() {
    core::arch::wasm32::unreachable()
}
