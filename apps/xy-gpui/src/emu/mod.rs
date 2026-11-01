//! High-level nihos RV32 Target Emulator for GPUI.

pub mod bus;
pub mod cpu;
pub mod elf;
mod tab5_i2c;

use bus::{Bus, FB_HEIGHT, FB_WIDTH};
use cpu::Cpu;
use elf::ElfLoader;
use std::path::{Path, PathBuf};

pub struct Emulator {
    pub bus: Bus,
    pub cpu: Cpu,
    pub cpu1: Option<Cpu>,
    pub elf_path: PathBuf,
    pub dict_path: Option<PathBuf>,
    pub paused: bool,
    pub total_steps: u64,
    pub mips: f32,
}

impl Emulator {
    pub fn new(
        elf_path: impl AsRef<Path>,
        dict_path: Option<impl AsRef<Path>>,
    ) -> std::io::Result<Self> {
        let elf_buf = elf_path.as_ref().to_path_buf();
        let dict_buf = dict_path.as_ref().map(|p| p.as_ref().to_path_buf());
        let mut bus = Bus::new();
        let entry_pc = ElfLoader::load_elf(&mut bus, &elf_buf)?;

        if let Some(dict) = &dict_buf {
            // Flash offset 0x0061_0000 (after 6MB factory partition)
            ElfLoader::load_dictionary(&mut bus, dict, 0x0061_0000)?;
        }

        let cpu = Cpu::new(entry_pc);
        Ok(Self {
            bus,
            cpu,
            cpu1: None,
            elf_path: elf_buf,
            dict_path: dict_buf,
            paused: false,
            total_steps: 0,
            mips: 0.0,
        })
    }

    pub fn fault(&self) -> Option<&str> {
        self.cpu
            .fault
            .as_deref()
            .or_else(|| self.cpu1.as_ref().and_then(|cpu| cpu.fault.as_deref()))
    }

    /// Reset CPU and reload memory from ELF and dictionary.
    pub fn reset(&mut self) -> std::io::Result<()> {
        let mut bus = Bus::new();
        let entry_pc = ElfLoader::load_elf(&mut bus, &self.elf_path)?;
        if let Some(dict) = &self.dict_path {
            ElfLoader::load_dictionary(&mut bus, dict, 0x0061_0000)?;
        }
        self.bus = bus;
        self.cpu = Cpu::new(entry_pc);
        self.cpu1 = None;
        self.total_steps = 0;
        self.mips = 0.0;
        Ok(())
    }

    /// Step execution for one display frame (~16.6 ms, e.g. 500,000 instructions).
    pub fn step_frame(&mut self, instructions: usize) {
        if self.paused {
            return;
        }
        let t0 = std::time::Instant::now();
        let mut executed = 0u64;
        for i in 0..instructions {
            let ok = self.cpu.step(&mut self.bus);
            executed += 1;
            if !ok {
                self.paused = true;
                break;
            }
            if let Some(entry) = self.bus.cpu1_entry.take() {
                let mut cpu = Cpu::new(entry);
                cpu.mhartid = 1;
                self.cpu1 = Some(cpu);
            }
            if i % 8 == 0
                && let Some(cpu) = &mut self.cpu1
            {
                for _ in 0..8 {
                    if !cpu.step(&mut self.bus) {
                        self.paused = true;
                        break;
                    }
                }
            }
            if self.paused {
                break;
            }
        }
        let elapsed = t0.elapsed().as_secs_f32();
        if elapsed > 0.0001 {
            let current_mips = (executed as f32 / elapsed) / 1_000_000.0;
            self.mips = if self.mips == 0.0 {
                current_mips
            } else {
                self.mips * 0.9 + current_mips * 0.1
            };
        }
        self.total_steps += executed;
    }

    /// Single-step instruction execution (for debugging / inspection).
    pub fn step_single(&mut self) {
        self.cpu.step(&mut self.bus);
        self.total_steps += 1;
    }

    /// Convert RGB565LE framebuffer directly into 32-bit BGRA for GPUI Metal rendering.
    pub fn render_to_bgra(&self, bgra: &mut [u8]) {
        assert_eq!(bgra.len(), FB_WIDTH * FB_HEIGHT * 4);

        for i in 0..(FB_WIDTH * FB_HEIGHT) {
            // Tab5 scanout is 720x1280. The nihos landscape UI uses
            // physical (x, y) = (logical_y, 1279 - logical_x).
            let x = i % FB_WIDTH;
            let y = i / FB_WIDTH;
            let physical = ((FB_WIDTH - 1 - x) * FB_HEIGHT + y) * 2;
            let p565 = self.bus.scanout.as_ref().map_or(0, |frame| {
                u16::from_le_bytes([frame[physical], frame[physical + 1]])
            });
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
    fn framebuffer_uses_display_base_and_mmu_mapping() {
        let mut bus = Bus::new();
        bus.psram[0] = 17;
        bus.write_u8(bus::FB_BASE, 42);
        assert_eq!(bus.framebuffer_byte(0), 42);
        bus.mmu_table[3] = 7;
        bus.psram[7 * 65536] = 99;
        assert_eq!(bus.framebuffer_byte(0), 99);
    }

    #[test]
    fn dma_requires_complete_valid_descriptor_and_latches_pixels() {
        let mut bus = Bus::new();
        let desc = 0x4ff1_0000;
        bus.write_u32(desc, bus::FB_BASE);
        bus.write_u32(desc + 8, 0x5010_5000);
        bus.write_u32(desc + 16, (bus::FB_SIZE / 8 - 1) as u32);
        bus.write_u32(desc + 32, 3 << 8);
        bus.write_u32(0x5008_1128, desc);
        bus.write_u32(0x5008_1018, 0x101);
        assert!(bus.scanout.is_none());
        assert_eq!(bus.read_u32(0x5008_1188), 0);
        bus.write_u8(bus::FB_BASE, 0xab);
        bus.write_u32(desc + 36, 0xc000_0000);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!(bus.scanout.as_ref().unwrap()[0], 0xab);
        bus.timer_ticks += 1_000_000;
        assert_eq!(bus.read_u32(0x5008_1188), 2);
        bus.write_u8(bus::FB_BASE, 0xcd);
        assert_eq!(bus.scanout.as_ref().unwrap()[0], 0xab);
        bus.write_u32(0x5008_1198, 2);
        assert_eq!(bus.read_u32(0x5008_1188), 0);
    }

    #[test]
    fn usb_fifo_and_timer_capture_have_guest_visible_state() {
        let mut bus = Bus::new();
        assert_eq!(bus.read_u32(0x500d_2004), 2);
        bus.keyboard_fifo.push(b'x');
        assert_eq!(bus.read_u32(0x500d_2004), 6);
        assert_eq!(bus.read_u32(0x500d_2000), b'x' as u32);
        bus.write_u32(0x500d_2000, b'y' as u32);
        assert_eq!(bus.console_output, b"y");
        bus.write_u32(0x500c_300c, 1);
        assert_eq!(bus.read_u32(0x500c_300c), 0);
    }

    #[test]
    fn timer_and_ipi_respect_hart_routes_and_acknowledgement() {
        let mut bus = Bus::new();
        bus.write_u32(0x2080_1040, 1 << 8);
        bus.write_u32(0x2080_1044, 1 << 8);
        bus.write_u32(0x500d_6000 + 46 * 4, 16);
        bus.write_u32(0x500d_6000 + 79 * 4, 17);
        bus.write_u32(0x500c_2070, 1);
        bus.write_u32(0x500c_2010, 10);
        bus.write_u32(0x500c_2000, (1 << 31) | (1 << 10));
        bus.timer_ticks = 9 * 360;
        assert_eq!(bus.pending_irq(0), None);
        bus.timer_ticks = 10 * 360;
        assert_eq!(bus.pending_irq(0), Some(16));
        assert_eq!(bus.pending_irq(1), None);
        bus.write_u32(0x500c_207c, 1);
        assert_eq!(bus.pending_irq(0), None);
        bus.write_u32(0x500e_5010, 1);
        assert_eq!(bus.pending_irq(0), Some(17));
        bus.write_u32(0x500e_5010, 0);
        assert_eq!(bus.pending_irq(0), None);
        bus.active_hart = 1;
        assert_eq!(bus.read_u32(0x2080_1040), 0);
    }

    #[test]
    fn unsupported_instruction_and_rom_call_halt_with_address() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4ff0_1000);
        bus.write_u32(cpu.pc, 0xffff_ffff);
        assert!(!cpu.step(&mut bus));
        assert!(cpu.fault.as_deref().unwrap().contains("0x4ff01000"));
        let mut compressed = Cpu::new(0x4ff0_2000);
        bus.write_u16(compressed.pc, 0x2000); // unsupported C.FLD
        assert!(!compressed.step(&mut bus));
        let mut rom = Cpu::new(0x4fc0_1234);
        assert!(!rom.step(&mut bus));
        assert!(rom.fault.as_deref().unwrap().contains("0x4fc01234"));
    }

    #[test]
    fn cpu1_rom_request_starts_second_hart_and_mcycle_advances() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_00a8);
        cpu.x[10] = 0x4ff0_1000;
        cpu.x[1] = 0x4ff0_2000;
        cpu.step(&mut bus);
        assert_eq!(bus.cpu1_entry, Some(0x4ff0_1000));
        // csrrs a0,mcycle,x0
        bus.write_u32(0x4ff0_2000, 0xb000_2573);
        cpu.step(&mut bus);
        assert_eq!(cpu.x[10], 1);
    }

    #[test]
    #[ignore = "requires NIHOS_EMU_MEOS_ELF"]
    fn meos_elf_reports_unsupported_flash_mapping() {
        let path = std::env::var("NIHOS_EMU_MEOS_ELF").expect("set NIHOS_EMU_MEOS_ELF");
        let error = match Emulator::new(path, None::<&str>) {
            Ok(_) => panic!("overlapping MeOS ELF must not be silently loaded"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);
    }

    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF and two extended boot runs"]
    fn two_sessions_boot_edit_and_reset_independently() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let boot = || {
            let mut emu = Emulator::new(&path, None::<&str>).unwrap();
            for _ in 0..1000 {
                emu.step_frame(1_000_000);
                let output = String::from_utf8_lossy(&emu.bus.console_output);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output.contains("NIHOS_NATIVE_XY_READY") {
                    emu.step_frame(90_000_000);
                    return emu;
                }
            }
            panic!("guest did not reach xy");
        };
        let (mut a, mut b) = std::thread::scope(|scope| {
            let first = scope.spawn(boot);
            let second = scope.spawn(boot);
            (first.join().unwrap(), second.join().unwrap())
        });
        let b_home = b.bus.scanout.clone().unwrap();
        let paused_steps = a.total_steps;
        let paused_pc = a.cpu.pc;
        let paused_frame = a.bus.scanout.clone();
        a.paused = true;
        a.step_frame(1_000_000);
        assert_eq!(a.total_steps, paused_steps);
        assert_eq!(a.cpu.pc, paused_pc);
        assert_eq!(a.bus.scanout, paused_frame);
        a.paused = false;
        a.send_key(b'n');
        a.step_frame(90_000_000);
        a.send_key(b'A');
        a.step_frame(90_000_000);
        assert!(a.bus.keyboard_fifo.is_empty());
        assert_eq!(b.bus.scanout.as_ref().unwrap(), &b_home);
        b.send_key(b'n');
        b.step_frame(90_000_000);
        b.send_key(b'B');
        b.step_frame(90_000_000);
        assert!(b.bus.keyboard_fifo.is_empty());
        assert!(
            a.bus.scanout != b.bus.scanout,
            "independently edited sessions must differ"
        );
        let b_document = b.bus.scanout.clone();
        a.reset().unwrap();
        a.step_frame(5_000_000);
        assert_eq!(b.bus.scanout, b_document);
        assert!(a.bus.scanout.is_none());
    }

    #[test]
    #[ignore = "requires a touch-enabled NIHOS_EMU_TEST_ELF"]
    fn touch_tap_reaches_xy_home() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        for _ in 0..2000 {
            emu.step_frame(500_000);
            assert!(
                !emu.paused,
                "CPU fault: {:?} / {:?}",
                emu.cpu.fault,
                emu.cpu1.as_ref().and_then(|cpu| cpu.fault.as_ref())
            );
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY")
                && output.contains("NIHOS_NATIVE_TOUCH_UI available=00000001")
            {
                emu.step_frame(30_000_000);
                let home = emu.bus.scanout.clone().expect("home frame");
                // Home's first card at logical (200, 220), panel (220, 1079).
                emu.bus.touch(Some((220, 1079)));
                emu.bus.touch(None);
                emu.step_frame(90_000_000);
                assert_ne!(
                    home,
                    *emu.bus.scanout.as_ref().unwrap(),
                    "touch did not navigate from home"
                );
                return;
            }
        }
        panic!(
            "touch not ready: {}",
            String::from_utf8_lossy(&emu.bus.console_output)
        );
    }

    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF and an extended boot run"]
    fn firmware_reaches_xy_ready() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let started = std::time::Instant::now();
        for _ in 0..2000 {
            emu.step_frame(500_000);
            assert!(
                !emu.paused,
                "CPU fault: {:?} / {:?}",
                emu.cpu.fault,
                emu.cpu1.as_ref().and_then(|cpu| cpu.fault.as_ref())
            );
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") {
                eprintln!(
                    "xy_ready cpu0_steps={} host_ms={}",
                    emu.total_steps,
                    started.elapsed().as_millis()
                );
                emu.step_frame(30_000_000);
                let home = emu.bus.scanout.clone().expect("home frame");
                emu.send_key(b'n');
                emu.step_frame(30_000_000);
                assert!(
                    emu.bus.keyboard_fifo.is_empty(),
                    "guest did not consume navigation input"
                );
                let document = emu.bus.scanout.clone().expect("document frame");
                assert_ne!(home, document, "navigation did not repaint the display");
                emu.send_key(b'X');
                emu.step_frame(30_000_000);
                assert!(
                    emu.bus.keyboard_fifo.is_empty(),
                    "guest did not consume editor input"
                );
                assert_ne!(
                    document,
                    *emu.bus.scanout.as_ref().unwrap(),
                    "editor input did not repaint the display"
                );
                return;
            }
        }
        panic!(
            "xy not ready pc0={:#x} pc1={:?} frames={} ra={:#x} sp={:#x}: {}",
            emu.cpu.pc,
            emu.cpu1.as_ref().map(|c| c.pc),
            emu.bus.scanout_frames,
            emu.cpu.x[1],
            emu.cpu.x[2],
            String::from_utf8_lossy(&emu.bus.console_output)
        );
    }

    // Requires a deliberately built xy firmware image. This is a gate, not a
    // passing test when the firmware or a display model is absent.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF"]
    fn firmware_reaches_splash() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        for _ in 0..100 {
            emu.step_frame(1_000_000);
            assert!(
                !emu.paused,
                "CPU fault: {:?} / {:?}",
                emu.cpu.fault,
                emu.cpu1.as_ref().and_then(|cpu| cpu.fault.as_ref())
            );
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_UI_START") {
                assert!(
                    emu.bus.scanout_frames >= 2,
                    "guest must consume two frames before UI start"
                );
                let mut bgra = vec![0; bus::FB_WIDTH * bus::FB_HEIGHT * 4];
                emu.render_to_bgra(&mut bgra);
                let unique: std::collections::HashSet<_> =
                    bgra.chunks_exact(4).map(|p| [p[0], p[1], p[2]]).collect();
                assert!(unique.len() > 10, "scanout frame lacks expected colors");
                if let Ok(path) = std::env::var("NIHOS_EMU_FRAME_PPM") {
                    use std::io::Write;
                    let mut file = std::fs::File::create(path).unwrap();
                    write!(file, "P6\n{} {}\n255\n", bus::FB_WIDTH, bus::FB_HEIGHT).unwrap();
                    for p in bgra.chunks_exact(4) {
                        file.write_all(&[p[2], p[1], p[0]]).unwrap();
                    }
                }
                return;
            }
        }
        panic!(
            "splash was not reached: {}",
            String::from_utf8_lossy(&emu.bus.console_output)
        );
    }
}
