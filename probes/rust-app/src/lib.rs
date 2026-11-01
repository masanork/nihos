#![no_std]

use core::panic::PanicInfo;
mod app;

#[unsafe(no_mangle)]
pub extern "C" fn nih_rust_app_frame(selected: u32) -> i32 {
    if selected > 1 {
        return -1;
    }
    app::draw(&mut nihos_app::Native, selected == 1)
        .err()
        .unwrap_or(0)
}

// Experimental native task entry; the kernel calls this on a task stack.
#[cfg(feature = "native-task")]
unsafe extern "C" {
    fn nih_rust_task_begin(argument: u32) -> i32;
    fn nih_rust_task_end() -> i32;
}

#[cfg(feature = "native-task")]
#[unsafe(no_mangle)]
pub extern "C" fn nih_rust_task_entry(argument: u32) -> i32 {
    // SAFETY: the native fixture registers this entry with its task gateway;
    // the kernel validates and owns task context and the scalar arguments.
    unsafe {
        if nih_rust_task_begin(argument) != 0 {
            return -10;
        }
        if nihos_app::task::sleep(0) != Err(-2) {
            return -15;
        }
        let before = nihos_app::task::ticks();
        if nihos_app::task::sleep(3).is_err() {
            return -11;
        }
        let after = nihos_app::task::ticks();
        if after.wrapping_sub(before) < 3 {
            return -12;
        }
        if nihos_app::task::yield_now().is_err() {
            return -13;
        }
        if nih_rust_task_end() != 0 {
            return -14;
        }
    }
    40 + argument as i32
}

#[panic_handler]
fn panic(_: &PanicInfo<'_>) -> ! {
    loop {
        core::hint::spin_loop();
    }
}
