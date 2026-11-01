#![no_std]

/// Experimental, synchronous application services. Coordinates are logical pixels.
/// Backends must copy or consume text before returning and never retain the slice.
pub trait Services {
    type Error;
    fn fill_rect(
        &mut self,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        rgb: u32,
    ) -> Result<(), Self::Error>;
    fn text(&mut self, x: i32, y: i32, text: &str, rgb: u32) -> Result<(), Self::Error>;
}

/// Trusted native caller. The host must implement the ABI contract documented in
/// docs/planning/rust-app-sdk.md. No native memory isolation is implied.
#[cfg(not(target_arch = "wasm32"))]
pub struct Native;

#[cfg(not(target_arch = "wasm32"))]
unsafe extern "C" {
    fn nih_app_fill_rect(x: i32, y: i32, width: u32, height: u32, rgb: u32) -> i32;
    fn nih_app_text(x: i32, y: i32, bytes: *const u8, len: u32, rgb: u32) -> i32;
}

#[cfg(not(target_arch = "wasm32"))]
impl Services for Native {
    type Error = i32;
    fn fill_rect(&mut self, x: i32, y: i32, width: u32, height: u32, rgb: u32) -> Result<(), i32> {
        // SAFETY: this call carries only scalars; backend follows the SDK contract.
        let status = unsafe { nih_app_fill_rect(x, y, width, height, rgb) };
        if status == 0 { Ok(()) } else { Err(status) }
    }
    fn text(&mut self, x: i32, y: i32, text: &str, rgb: u32) -> Result<(), i32> {
        let len = u32::try_from(text.len()).map_err(|_| -1)?;
        // SAFETY: text is readable for len bytes for the synchronous call. The
        // backend must not retain the pointer or write through it.
        let status = unsafe { nih_app_text(x, y, text.as_ptr(), len, rgb) };
        if status == 0 { Ok(()) } else { Err(status) }
    }
}

/// Experimental scalar task calls, usable only from a registered native task.
/// The kernel owns cancellation and task resources; forced termination does not
/// run Rust destructors. No task creation or isolation is provided here.
#[cfg(feature = "native-task")]
pub mod task {
    unsafe extern "C" {
        fn nih_riscv_task_call(number: u32, argument: u32, payload: u32) -> u64;
    }
    fn call(number: u32, argument: u32) -> u64 {
        // SAFETY: native-task backend requires the nihos C ABI task gateway.
        // Callers must execute in a registered native task, not an ISR.
        unsafe { nih_riscv_task_call(number, argument, 0) }
    }
    fn status(value: u64) -> Result<(), i32> {
        if value == 0 {
            Ok(())
        } else {
            Err(value as u32 as i32)
        }
    }
    pub fn ticks() -> u64 {
        call(0x4e49_0005, 0)
    }
    pub fn sleep(ticks: u32) -> Result<(), i32> {
        status(call(0x4e49_0001, ticks))
    }
    pub fn yield_now() -> Result<(), i32> {
        status(call(0x4e49_0000, 0))
    }
}

/// Wasm import backend. The embedding host must validate every memory range,
/// never retain it, and implement the same synchronous service semantics.
#[cfg(target_arch = "wasm32")]
pub struct Wasm;
#[cfg(target_arch = "wasm32")]
#[link(wasm_import_module = "nihos")]
unsafe extern "C" {
    fn nih_app_fill_rect(x: i32, y: i32, width: u32, height: u32, rgb: u32) -> i32;
    fn nih_app_text(x: i32, y: i32, bytes: *const u8, len: u32, rgb: u32) -> i32;
}
#[cfg(target_arch = "wasm32")]
impl Services for Wasm {
    type Error = i32;
    fn fill_rect(&mut self, x: i32, y: i32, width: u32, height: u32, rgb: u32) -> Result<(), i32> {
        // SAFETY: the Wasm host import follows the documented scalar contract.
        let code = unsafe { nih_app_fill_rect(x, y, width, height, rgb) };
        if code == 0 { Ok(()) } else { Err(code) }
    }
    fn text(&mut self, x: i32, y: i32, text: &str, rgb: u32) -> Result<(), i32> {
        let len = u32::try_from(text.len()).map_err(|_| -1)?;
        // SAFETY: the slice is live during the synchronous import; the host
        // validates the linear-memory range and must not retain the pointer.
        let code = unsafe { nih_app_text(x, y, text.as_ptr(), len, rgb) };
        if code == 0 { Ok(()) } else { Err(code) }
    }
}
