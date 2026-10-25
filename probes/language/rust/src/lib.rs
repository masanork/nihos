#![no_std]

use core::panic::PanicInfo;

const ABI_VERSION: u32 = 1;
const RING_CAPACITY: usize = 64;

#[repr(C)]
pub struct Result {
    abi_version: u32,
    checksum: u32,
    processed: u32,
    rejected: u32,
}

fn consume(value: u8, result: &mut Result) {
    result.checksum = (result.checksum ^ u32::from(value)).wrapping_mul(16_777_619);
    result.processed = result.processed.wrapping_add(1);
}

/// # Safety
///
/// `output` must point to writable `Result` storage. If `length` is nonzero,
/// `input` must point to at least `length` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nihos_probe_run(
    input: *const u8,
    length: usize,
    output: *mut Result,
) -> i32 {
    if output.is_null() {
        return -1;
    }
    if input.is_null() && length != 0 {
        return -2;
    }

    // SAFETY: The caller contract above requires valid output storage.
    let result = unsafe { &mut *output };
    *result = Result {
        abi_version: ABI_VERSION,
        checksum: 2_166_136_261,
        processed: 0,
        rejected: 0,
    };

    let mut ring = [0_u8; RING_CAPACITY];
    let mut head = 0_usize;
    let mut tail = 0_usize;
    let mut count = 0_usize;

    for index in 0..length {
        // SAFETY: The caller contract requires `length` readable bytes.
        let value = unsafe { *input.add(index) };
        if value == u8::MAX {
            result.rejected = result.rejected.wrapping_add(1);
            continue;
        }
        if count == RING_CAPACITY {
            consume(ring[head], result);
            head = (head + 1) % RING_CAPACITY;
            count -= 1;
        }
        ring[tail] = value;
        tail = (tail + 1) % RING_CAPACITY;
        count += 1;
    }

    while count != 0 {
        consume(ring[head], result);
        head = (head + 1) % RING_CAPACITY;
        count -= 1;
    }
    0
}

#[panic_handler]
fn panic(_info: &PanicInfo<'_>) -> ! {
    loop {
        core::hint::spin_loop();
    }
}
