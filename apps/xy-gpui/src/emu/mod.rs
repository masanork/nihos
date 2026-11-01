//! High-level nihos RV32 Target Emulator for GPUI.

pub mod bus;
pub mod cpu;
pub mod elf;

use bus::{Bus, FB_HEIGHT, FB_WIDTH};
use cpu::Cpu;
use elf::ElfLoader;
use std::path::Path;

pub struct Emulator {
    pub bus: Bus,
    pub cpu: Cpu,
}

impl Emulator {
    pub fn new(
        elf_path: impl AsRef<Path>,
        dict_path: Option<impl AsRef<Path>>,
    ) -> std::io::Result<Self> {
        let mut bus = Bus::new();
        let entry_pc = ElfLoader::load_elf(&mut bus, elf_path)?;

        if let Some(dict) = dict_path {
            // Flash offset 0x0061_0000 (after 6MB factory partition)
            let _ = ElfLoader::load_dictionary(&mut bus, dict, 0x0061_0000);
        }

        let cpu = Cpu::new(entry_pc);
        Ok(Self { bus, cpu })
    }

    /// Step execution for one display frame (~16.6 ms, e.g. 500,000 instructions).
    pub fn step_frame(&mut self, instructions: usize) {
        for _ in 0..instructions {
            self.cpu.step(&mut self.bus);
        }
    }

    /// Read raw RGB565 framebuffer from emulated PSRAM.
    pub fn framebuffer_rgb565(&self) -> &[u8] {
        self.bus.framebuffer()
    }

    /// Convert RGB565LE framebuffer directly into 32-bit BGRA for GPUI Metal rendering.
    pub fn render_to_bgra(&self, bgra: &mut [u8]) {
        assert_eq!(bgra.len(), FB_WIDTH * FB_HEIGHT * 4);
        let fb = self.framebuffer_rgb565();

        for i in 0..(FB_WIDTH * FB_HEIGHT) {
            let p565 = u16::from_le_bytes([fb[i * 2], fb[i * 2 + 1]]);
            // Extract RGB565 components and scale to 8-bit
            let r = ((p565 >> 11) & 0x1f) as u8;
            let g = ((p565 >> 5) & 0x3f) as u8;
            let b = (p565 & 0x1f) as u8;

            let r8 = (r << 3) | (r >> 2);
            let g8 = (g << 2) | (g >> 4);
            let b8 = (b << 3) | (b >> 2);

            // BGRA layout for Apple Silicon Metal
            bgra[i * 4] = b8;
            bgra[i * 4 + 1] = g8;
            bgra[i * 4 + 2] = r8;
            bgra[i * 4 + 3] = 0xff;
        }
    }

    /// Inject an ASCII or HID key event from the GPUI window into the emulator.
    pub fn send_key(&mut self, key_char: u8) {
        self.bus.keyboard_fifo.push(key_char);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_load_and_step_nihos_firmware() {
        let elf_path = "../../build/native-emulator/nihos-native.elf";
        if !std::path::Path::new(elf_path).exists() {
            println!("Firmware ELF not found, skipping.");
            return;
        }

        let dict_path = "../../build/dict/jisyo_l_nfst.bin";
        let mut emu =
            Emulator::new(elf_path, Some(dict_path)).expect("Failed to initialize emulator");

        assert_eq!(emu.cpu.pc, 0x4ff2_0000);
        println!("Initial PC: {:#x}", emu.cpu.pc);

        let mut prev_pc = 0;
        let mut prev_raw = 0;
        for i in 0..10_000_000 {
            let pc = emu.cpu.pc;
            if !(0x4ff2_0000..=0x4ff3_4000).contains(&pc)
                && !(0x4000_0000..=0x4002_0000).contains(&pc)
                && !(0x4fc0_0000..=0x4fc0_ffff).contains(&pc)
            {
                println!(
                    "Jumped out of valid range at step {}: PC={:#010x} (Prev PC={:#010x}, Prev Inst={:#010x})",
                    i, pc, prev_pc, prev_raw
                );
                break;
            }
            prev_pc = pc;
            prev_raw = emu.bus.read_u32(pc);
            emu.cpu.step(&mut emu.bus);
        }

        let console = String::from_utf8_lossy(&emu.bus.console_output);
        println!(
            "--- Console Output ({} bytes) ---",
            emu.bus.console_output.len()
        );
        print!("{}", console);
        println!("---------------------------------");

        let mut non_zero_fb = 0;
        for &b in emu.framebuffer_rgb565() {
            if b != 0 {
                non_zero_fb += 1;
            }
        }
        println!(
            "Non-zero framebuffer bytes: {} / {}",
            non_zero_fb,
            bus::FB_SIZE
        );
    }
}
