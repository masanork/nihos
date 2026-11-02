//! High-level nihos RV32 Target Emulator for GPUI.

pub mod bus;
pub mod cpu;
pub mod elf;
mod tab5_i2c;

use bus::{Bus, FB_HEIGHT, FB_WIDTH};
use cpu::Cpu;
use elf::ElfLoader;
use std::path::{Path, PathBuf};

#[cfg(test)]
struct GcInstructionProbe {
    entry: u32,
    active: Option<(u32, u64)>,
    samples: Vec<u64>,
}

pub struct Emulator {
    pub bus: Bus,
    pub cpu: Cpu,
    pub cpu1: Option<Cpu>,
    pub elf_path: PathBuf,
    pub dict_path: Option<PathBuf>,
    pub paused: bool,
    pub total_steps: u64,
    pub mips: f32,
    #[cfg(test)]
    gc_probe: Option<GcInstructionProbe>,
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
            #[cfg(test)]
            gc_probe: None,
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
        #[cfg(test)]
        { self.gc_probe = None; }
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
            #[cfg(test)]
            if let Some(probe) = &mut self.gc_probe {
                if let Some((return_pc, start)) = probe.active {
                    if self.cpu.pc == return_pc {
                        probe.samples.push(self.cpu.instructions_executed - start);
                        probe.active = None;
                    }
                } else if self.cpu.pc == probe.entry {
                    probe.active = Some((self.cpu.x[1], self.cpu.instructions_executed));
                }
            }
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
    fn disconnected_keyboard_bus_has_independent_open_drain_lines() {
        let mut bus = Bus::new();
        assert_eq!(bus.read_u32(0x500e_003c) & 3, 3);
        bus.write_u32(0x500e_0024, 1);
        assert_eq!(bus.read_u32(0x500e_003c) & 3, 2);
        bus.write_u32(0x500e_0024, 2);
        assert_eq!(bus.read_u32(0x500e_003c) & 3, 0);
        bus.write_u32(0x500e_0028, 3);
        assert_eq!(bus.read_u32(0x500e_003c) & 3, 3);
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
    fn timer_alarm_latches_without_irq_poll() {
        let mut bus = Bus::new();
        bus.write_u32(0x500c_2010, 10);
        bus.write_u32(0x500c_2000, (1 << 31) | (1 << 10));
        bus.timer_ticks = 9 * 360;
        assert_eq!(bus.read_u32(0x500c_2078) & 1, 0);
        bus.timer_ticks = 10 * 360;
        // Peripheral status latches even when CPU interrupts are disabled and
        // the interrupt router has not been polled.
        assert_eq!(bus.read_u32(0x500c_2078) & 1, 1);
        assert_eq!(bus.read_u32(0x500c_2000) & (1 << 10), 0);
        bus.write_u32(0x500c_207c, 1);
        assert_eq!(bus.read_u32(0x500c_2078) & 1, 0);
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
        // The enabled touch service and editor can repaint at different times.
        // Wait for both sessions to present distinct edits, with a bound.
        for _ in 0..4 {
            if a.bus.scanout != b.bus.scanout {
                break;
            }
            a.step_frame(30_000_000);
            b.step_frame(30_000_000);
            assert!(
                !a.paused && !b.paused,
                "guest fault while waiting for edits"
            );
        }
        assert!(
            a.bus.scanout != b.bus.scanout,
            "independent inputs did not produce distinct frames"
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
                // The first home card uses the same visual point in either
                // orientation, translated back into physical panel coordinates.
                let portrait = String::from_utf8_lossy(&emu.bus.console_output)
                    .lines()
                    .any(|line| {
                        line.starts_with("NIHOS_NATIVE_XY_READY ")
                            && line.contains("portrait=00000001")
                    });
                emu.bus
                    .touch(Some(if portrait { (200, 220) } else { (220, 1079) }));
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
    #[ignore = "requires a keyboard-probing NIHOS_EMU_TEST_ELF with automatic orientation"]
    fn absent_keyboard_selects_portrait() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        for _ in 0..2000 {
            emu.step_frame(500_000);
            assert!(!emu.paused, "guest CPU fault: {:?}", emu.fault());
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if let Some(line) = output
                .lines()
                .find(|line| line.starts_with("NIHOS_NATIVE_XY_READY "))
            {
                assert!(
                    line.contains("portrait=00000001") && line.contains("keyboard_probe=00000001"),
                    "{line}"
                );
                return;
            }
        }
        panic!(
            "guest not ready: {}",
            String::from_utf8_lossy(&emu.bus.console_output)
        );
    }

    // Also exercises a guest built with PR #125's forced-portrait fixture.
    #[test]
    #[ignore = "requires a portrait and touch-enabled NIHOS_EMU_TEST_ELF"]
    fn portrait_touch_opens_document_and_types() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        for _ in 0..2000 {
            emu.step_frame(500_000);
            assert!(!emu.paused, "guest CPU fault: {:?}", emu.fault());
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.lines().any(|line| {
                line.starts_with("NIHOS_NATIVE_XY_READY ") && line.contains("portrait=00000001")
            }) && output.contains("NIHOS_NATIVE_TOUCH_UI available=00000001")
            {
                emu.step_frame(30_000_000);
                let home = emu.bus.scanout.clone().expect("home frame");
                emu.bus.touch(Some((200, 220)));
                emu.bus.touch(None);
                emu.step_frame(90_000_000);
                let document = emu.bus.scanout.clone().expect("document frame");
                assert!(home != document, "portrait tap did not open document");
                // q is in the first row of the portrait software keyboard.
                emu.bus.touch(Some((36, 1000)));
                emu.bus.touch(None);
                emu.step_frame(90_000_000);
                assert!(
                    document != *emu.bus.scanout.as_ref().unwrap(),
                    "soft key did not repaint document"
                );
                return;
            }
        }
        panic!(
            "portrait touch not ready: {}",
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

    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_reports_xy_backing_allocation() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        for _ in 0..3000 {
            emu.step_frame(1_000_000);
            assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if let Some(line) = output.lines().find(|line| line.contains("NIHOS_NATIVE_XY_IDLE ")) {
                eprintln!("xy_backing {line}");
                assert!(line.contains("backing_reserved=00400000"), "{line}");
                return;
            }
        }
        panic!("no backing allocation report: {}", String::from_utf8_lossy(&emu.bus.console_output));
    }

    // Requires an xy trace ELF built from the exact candidate under test.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_nested_gc_pressure_and_recovery() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let expected = std::env::var("NIHOS_EMU_GC_EXPECT").expect("set NIHOS_EMU_GC_EXPECT to done or full");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") { ready = true; break; }
        }
        assert!(ready, "guest did not reach xy");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        let mut run = |source: &str, expected_reply: &str| {
            assert!(source.len() < 256);
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            if source == "(let ((result (work 3))) result)" {
                if let Ok(entry) = std::env::var("NIHOS_EMU_GC_ENTRY") {
                    emu.gc_probe = Some(GcInstructionProbe {
                        entry: u32::from_str_radix(entry.trim_start_matches("0x"), 16).expect("invalid GC entry"),
                        active: None,
                        samples: Vec::new(),
                    });
                }
            }
            for byte in source.bytes().chain(std::iter::once(b'\r')) { emu.send_key(byte); }
            let hex: String = expected_reply.bytes().map(|b| format!("{b:02x}")).collect();
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={hex}");
            let mut checkpoint = start;
            let cancel = std::env::var_os("NIHOS_EMU_GC_CANCEL").is_some();
            let abort = std::env::var_os("NIHOS_EMU_GC_ABORT").is_some();
            let inject = source == "(let ((result (work 3))) result)" && (abort || cancel || std::env::var_os("NIHOS_EMU_GC_INJECT").is_some());
            let mut injected = false;
            for _ in 0..if inject { 3000 } else { 200 } {
                emu.step_frame(if inject { 100_000 } else { 5_000_000 });
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if inject && !injected && output.contains("NIHOS_XY_GC_PUMP_ACTIVE") {
                    emu.send_key(if cancel || abort { 3 } else { b'z' });
                    injected = true;
                    continue;
                }
                if !emu.bus.keyboard_fifo.is_empty() {
                    checkpoint = emu.bus.console_output.len();
                    continue;
                }
                let completed = String::from_utf8_lossy(&emu.bus.console_output[checkpoint..]);
                let reply_seen = completed.lines().any(|line| line.trim_end_matches('\r') == expected_line);
                let replay_marker = if cancel { "NIHOS_NATIVE_XY_READER screen=00000001" } else { "bytes=00000001" };
                let replayed = if abort { reply_seen } else { inject && output.contains("NIHOS_XY_GC_RESULT done") && output.contains(replay_marker) };
                if if inject { replayed } else { reply_seen } {
                    if inject {
                        if abort {
                            let seen = output.find("NIHOS_XY_GC_CANCEL_SEEN").expect("cancel not observed during GC");
                            let safe = output.find("NIHOS_XY_GC_CANCEL_SAFE").expect("collector did not complete after cancel");
                            let result = output.find("NIHOS_XY_GC_RESULT Evaluation cancelled").expect("missing cancellation result");
                            assert!(injected && seen < safe && safe < result, "invalid cancellation ordering: {output}");
                        } else {
                            assert!(injected && output.contains("NIHOS_XY_GC_DEFERRED"), "input was not deferred during GC: {output}");
                            assert!(output.contains(replay_marker), "deferred input was not replayed: {output}");
                        }
                        if std::env::var_os("NIHOS_EMU_GC_REPAINT").is_some() {
                            assert!(output.contains("NIHOS_XY_GC_REPAINT"), "no repaint while collecting: {output}");
                        }
                        if std::env::var_os("NIHOS_EMU_GC_OVERLAP").is_some() {
                            assert!(output.contains("NIHOS_XY_GC_OVERLAP_REJECTED"), "overlap test missing: {output}");
                            eprintln!("gc_foreground overlapping_stack=rejected");
                        }
                        if std::env::var_os("NIHOS_EMU_GC_TRAPS").is_some() {
                            let line = output.lines().find(|line| line.contains("NIHOS_XY_GC_STACK_CAPTURES"))
                                .expect("missing GC stack capture counters");
                            let counter = |name: &str| {
                                let value = line.split_whitespace().find_map(|part| part.strip_prefix(name)).expect("missing stack counter");
                                u32::from_str_radix(value, 16).expect("invalid stack counter")
                            };
                            let eval = counter("eval=");
                            let render = counter("render=");
                            assert!(eval > 0 && render > 0, "timer capture missing: {line}");
                            eprintln!("gc_stack_captures eval={eval} render={render}");
                        }
                        eprintln!("gc_input pump=active repaint={} result={} replay={}", output.contains("NIHOS_XY_GC_REPAINT"), if abort { "cancelled" } else { "done" }, if abort { "none" } else if cancel { "cancel-home" } else { "text" });
                        if cancel {
                            let resume = emu.bus.console_output.len();
                            emu.send_key(b'n');
                            let mut returned = false;
                            for _ in 0..200 {
                                emu.step_frame(5_000_000);
                                let state = String::from_utf8_lossy(&emu.bus.console_output[resume..]);
                                if state.contains("NIHOS_NATIVE_XY_READER screen=00000000") { returned = true; break; }
                            }
                            assert!(returned, "could not return to scratch after deferred cancel");
                        }
                    }
                    eprintln!("nested_gc source_len={} reply={expected_reply}", source.len());
                    if let Some(probe) = emu.gc_probe.take() {
                        assert!(probe.active.is_none(), "GC probe ended inside collection");
                        assert!(!probe.samples.is_empty(), "GC entry not observed");
                        let count = probe.samples.len();
                        let total: u64 = probe.samples.iter().sum();
                        let min = probe.samples.iter().min().unwrap();
                        let max = probe.samples.iter().max().unwrap();
                        eprintln!("gc_cpu0_instructions count={count} total={total} min={min} max={max} first={:?}", &probe.samples[..count.min(8)]);
                    }
                    return;
                }
            }
            panic!("missing expected reply for {source}: {}", String::from_utf8_lossy(&emu.bus.console_output[start..]));
        };
        let root = format!("(define root '({}))", vec!["0"; 116].join(" "));
        run(&root, "()");
        for _ in 0..5 { run("(set! root (append root root))", "()"); }
        run("(define (alloc n acc) (if (= n 0) acc (alloc (- n 1) (cons n acc))))", "()");
        run("(define (work n) (if (= n 0) 'done (begin (let ((a (alloc 70 '()))) (let ((b (alloc 70 '()))) (+ (length a) (length b)))) (work (- n 1)))))", "()");
        let reply = match expected.as_str() { "done" => "done", "full" => "Scheme heap full", "cancelled" => "Evaluation cancelled", _ => panic!("invalid NIHOS_EMU_GC_EXPECT") };
        run("(let ((result (work 3))) result)", reply);
        run("(+ 20 22)", "42");
    }

    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_evaluates_extended_scheme() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") {
                ready = true;
                break;
            }
        }
        assert!(ready, "guest did not reach xy");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, expected) in [
            ("(+ 1/3 1/2)", "NIHOS_NATIVE_XY_REPLY data=352f36"),
            ("(+ 2.7 10)", "NIHOS_NATIVE_XY_REPLY data=31322e37"),
            (
                "(begin 9406149299205461e-16)",
                "NIHOS_NATIVE_XY_REPLY data=302e39343036313439323939323035343631",
            ),
            (
                "(+ 0.1 0.2)",
                "NIHOS_NATIVE_XY_REPLY data=302e3330303030303030303030303030303034",
            ),
            ("(begin 1e-23)", "NIHOS_NATIVE_XY_REPLY data=31652d3233"),
            ("(begin 5e-324)", "NIHOS_NATIVE_XY_REPLY data=35652d333234"),
            ("(+ 1/2 .25)", "NIHOS_NATIVE_XY_REPLY data=302e3735"),
            (
                "(list (exact .5) (inexact 1/2))",
                "NIHOS_NATIVE_XY_REPLY data=28312f3220302e3529",
            ),
            ("(/ -1.0 0.0)", "NIHOS_NATIVE_XY_REPLY data=2d696e662e30"),
            ("(/ 0.0 0.0)", "NIHOS_NATIVE_XY_REPLY data=2b6e616e2e30"),
            ("(begin #e0.1)", "NIHOS_NATIVE_XY_REPLY data=312f3130"),
            ("(= 1/10 0.1)", "NIHOS_NATIVE_XY_REPLY data=2366"),
            ("(< 1/10 0.1)", "NIHOS_NATIVE_XY_REPLY data=2374"),
            (
                "(list (round -5/2) (round 3.5))",
                "NIHOS_NATIVE_XY_REPLY data=282d3220342e3029",
            ),
            (
                "(list (odd? -3) (even? 4.0))",
                "NIHOS_NATIVE_XY_REPLY data=28237420237429",
            ),
            (
                "(list (quotient -5 2) (remainder -5 2) (modulo -5 2))",
                "NIHOS_NATIVE_XY_REPLY data=282d32202d31203129",
            ),
            (
                "(list (gcd 32 -36) (lcm 32.0 -36))",
                "NIHOS_NATIVE_XY_REPLY data=2834203238382e3029",
            ),
            (
                "(list (numerator -6/4) (denominator 1.5) (square 2/3))",
                "NIHOS_NATIVE_XY_REPLY data=282d3320322e3020342f3929",
            ),
            (
                "(list (min 3 1/2 -1) (max 3.0 4) (expt 2 -3))",
                "NIHOS_NATIVE_XY_REPLY data=282d3120342e3020312f3829",
            ),
            ("(begin #I#XFF/2)", "NIHOS_NATIVE_XY_REPLY data=3132372e35"),
            ("(apply + 1 '(2 3))", "NIHOS_NATIVE_XY_REPLY data=36"),
            (
                "(begin (define (ap-loop n) (if (= n 0) 17 (apply ap-loop (list (- n 1))))) (ap-loop 120))",
                "NIHOS_NATIVE_XY_REPLY data=3137",
            ),
            (
                "(begin (define (count n) (if (= n 0) 19 (count (- n 1)))) (count 200))",
                "NIHOS_NATIVE_XY_REPLY data=3139",
            ),
            (
                "(begin (define (cond-loop n) (cond ((= n 0) 23) ((- n 1) => cond-loop))) (cond-loop 180))",
                "NIHOS_NATIVE_XY_REPLY data=3233",
            ),
            (
                "(begin (define (gc-loop n) (if (= n 0) 29 (apply gc-loop (list (- n 1))))) (gc-loop 450))",
                "NIHOS_NATIVE_XY_REPLY data=3239",
            ),
            (
                "(begin (define d '(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)) (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) 31)",
                "NIHOS_NATIVE_XY_REPLY data=3331",
            ),
            (
                "(begin (define (worker n) (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) (if (= n 0) 33 (worker (- n 1)))) (worker 2))",
                "NIHOS_NATIVE_XY_REPLY data=3333",
            ),
            (
                "(let ((x d)) (append x x x x x x) (append x x x x x x) (append x x x x x x) (append x x x x x x) (append x x x x x x) (append x x x x x x) (+ 37 (car x)))",
                "NIHOS_NATIVE_XY_REPLY data=3337",
            ),
            (
                "(cond (#t (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) (+ 39 (car d))))",
                "NIHOS_NATIVE_XY_REPLY data=3339",
            ),
            (
                "(and (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) (append d d d d d d) 41)",
                "NIHOS_NATIVE_XY_REPLY data=3431",
            ),
            (
                "(or (begin (append d d d d d d) #f) (begin (append d d d d d d) #f) (begin (append d d d d d d) #f) (begin (append d d d d d d) #f) (begin (append d d d d d d) #f) (begin (append d d d d d d) #f) 43)",
                "NIHOS_NATIVE_XY_REPLY data=3433",
            ),
            (
                "(cond ((begin (append d d d d d d) #f) 0) ((begin (append d d d d d d) #f) 0) ((begin (append d d d d d d) #f) 0) ((begin (append d d d d d d) #f) 0) ((begin (append d d d d d d) #f) 0) ((begin (append d d d d d d) #f) 0) (else 47))",
                "NIHOS_NATIVE_XY_REPLY data=3437",
            ),
            (
                "(let ((a (begin (append d d d d d d) 1)) (b (begin (append d d d d d d) 1)) (c (begin (append d d d d d d) 1)) (d (begin (append d d d d d d) 1)) (e (begin (append d d d d d d) 1)) (f (begin (append d d d d d d) 1))) (+ a b c d e f 43))",
                "NIHOS_NATIVE_XY_REPLY data=3439",
            ),
            (
                "(/ 1 0)",
                "NIHOS_NATIVE_XY_REPLY data=4469766973696f6e206279207a65726f",
            ),
            ("(+ 70 7)", "NIHOS_NATIVE_XY_REPLY data=3737"),
            (
                "(/ 1.0 0)",
                "NIHOS_NATIVE_XY_REPLY data=4469766973696f6e206279207a65726f",
            ),
            ("(+ 20 22)", "NIHOS_NATIVE_XY_REPLY data=3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000); // Resolve the serial Escape timeout.
            for byte in source.bytes().chain(std::iter::once(b'\r')) {
                emu.send_key(byte);
            }
            let mut matched = false;
            for _ in 0..200 {
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output
                    .lines()
                    .any(|line| line.trim_end_matches('\r') == expected)
                {
                    matched = true;
                    eprintln!("xy_scheme_emulator source={source} reply={expected}");
                    break;
                }
            }
            assert!(
                matched,
                "no expected reply for {source}: {}",
                String::from_utf8_lossy(&emu.bus.console_output[start..])
            );
        }
    }

    // Sequential official exercise forms require one persistent xy session.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_evaluates_sicp_exercises_1_1_to_1_5() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") {
                ready = true;
                break;
            }
        }
        assert!(ready, "guest did not reach xy");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, expected) in [
            // Scratch treats bare tokens as command names; wrap the literal.
            ("(begin 10)", "3130"),
            ("(+ 5 3 4)", "3132"),
            ("(- 9 1)", "38"),
            ("(/ 6 2)", "33"),
            ("(+ (* 2 4) (- 4 6))", "36"),
            // Distinct markers ensure each asynchronous definition completed.
            ("(begin (define a 3) 301)", "333031"),
            ("(begin (define b (+ a 1)) 302)", "333032"),
            ("(+ a b (* a b))", "3139"),
            ("(= a b)", "2366"),
            ("(if (and (> b a) (< b (* a b))) b a)", "34"),
            ("(cond ((= a 4) 6) ((= b 4) (+ 6 7 a)) (else 25))", "3136"),
            ("(+ 2 (if (> b a) b a))", "36"),
            (
                "(* (cond ((> a b) a) ((< a b) b) (else -1)) (+ a 1))",
                "3136",
            ),
            (
                "(/ (+ 5 4 (- 2 (- 3 (+ 6 (/ 4 5))))) (* 3 (- 6 2) (- 2 7)))",
                "2d33372f313530",
            ),
            (
                "(begin (define (two-square a b c) (let ((m (min a b c))) (- (+ (* a a) (* b b) (* c c)) (* m m)))) 501)",
                "353031",
            ),
            ("(two-square 4 7 2)", "3635"),
            ("(two-square -3 -2 -1)", "35"),
            (
                "(begin (define (a-plus-abs-b a b) ((if (> b 0) + -) a b)) 502)",
                "353032",
            ),
            ("(a-plus-abs-b 5 -4)", "39"),
            (
                "(begin (define (p) (p)) (define (test x y) (if (= x 0) 0 y)) 503)",
                "353033",
            ),
            ("(test 0 (p))", "4576616c756174696f6e20627564676574"),
            ("(+ 20 22)", "3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            for byte in source.bytes().chain(std::iter::once(b'\r')) {
                emu.send_key(byte);
            }
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={expected}");
            let mut matched = false;
            for _ in 0..200 {
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output
                    .lines()
                    .any(|line| line.trim_end_matches('\r') == expected_line)
                {
                    matched = true;
                    eprintln!("sicp_1_1 source={source} reply={expected_line}");
                    break;
                }
            }
            assert!(
                matched,
                "no expected reply for {source}: {}",
                String::from_utf8_lossy(&emu.bus.console_output[start..])
            );
        }
    }

    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_evaluates_sicp_list_exercises() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") { ready = true; break; }
        }
        assert!(ready, "guest did not reach xy");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, expected) in [
            ("(map (lambda (x) (* x x)) '(1 2 3 4))", "28312034203920313629"),
            ("(map + '(1 2 3) '(10 20 30))", "28313120323220333329"),
            ("(begin (define (many n a) (if (= n 0) a (many (- n 1) (cons 1 a)))) (if (equal? (many 129 '()) (many 129 '())) 709 708))", "373039"),
            ("(if (equal? '(a (b c)) '(a (b c))) 710 711)", "373130"),
            ("(if (equal? '(a (b c)) '(a (b d))) 712 713)", "373133"),
            ("(memq 'red '(red shoes blue socks))", "287265642073686f657320626c756520736f636b7329"),
            ("(cadr '((x1 x2) (y1 y2)))", "28793120793229"),
            ("(let* ((x 1) (f (lambda () x)) (x 2)) (f))", "31"),
            ("(let* ((n 6) (d -8) (g (gcd n d)) (a (/ n g)) (b (/ d g))) (cons (- a) (- b)))", "282d33202e203429"),
            ("(map + '(1) '(2 3))", "57726f6e6720617267756d656e742074797065"),
            ("(+ 20 22)", "3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            for byte in source.bytes().chain(std::iter::once(b'\r')) { emu.send_key(byte); }
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={expected}");
            let mut matched = false;
            for _ in 0..200 {
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output.lines().any(|line| line.trim_end_matches('\r') == expected_line) {
                    eprintln!("sicp_lists source={source} reply={expected_line}");
                    matched = true;
                    break;
                }
            }
            assert!(matched, "no expected reply for {source}: {}", String::from_utf8_lossy(&emu.bus.console_output[start..]));
        }
    }

    // A bounded sample of the first five chapters, using scratch input.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_evaluates_sicp_five_chapter_samples() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") { ready = true; break; }
        }
        assert!(ready, "guest did not reach xy");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, expected) in [
            ("(begin (define (xp b n a) (cond ((= n 0) a) ((even? n) (xp (* b b) (quotient n 2) a)) (else (xp b (- n 1) (* a b))))) (xp 3 7 1))", "32313837"),
            ("(let* ((a (cons -3 2)) (b (cons 5 -4))) (cons (/ (+ (car a) (car b)) 2) (/ (+ (cdr a) (cdr b)) 2)))", "2831202e202d3129"),
            ("(let* ((a (let ((n 5)) (lambda (x) (set! n (+ n x)) n))) (x (a 10)) (y (a 10))) (list x y))", "28313520323529"),
            ("(let ((x (list 1 2))) (set-car! x 7) (set-cdr! (cdr x) x) (list (car x) (list? x)))", "283720236629"),
            ("(let ((q (cons '() '()))) (let ((n (list 'a))) (set-car! q n) (set-cdr! q n)) (let ((n (list 'b))) (set-cdr! (cdr q) n) (set-cdr! q n)) (car q))", "2861206229"),
            ("(let ((e '(define x 3))) (list (pair? e) (eq? (car e) 'call)))", "28237420236629"),
            ("(begin (define (fact n) (define (iter p c) (if (> c n) p (iter (* c p) (+ c 1)))) (iter 1 1)) (fact 5))", "313230"),

            ("(begin (define (same-parity f . r) (define (k xs) (cond ((null? xs) '()) ((= (remainder (abs (car xs)) 2) (remainder (abs f) 2)) (cons (car xs) (k (cdr xs)))) (else (k (cdr xs))))) (cons f (k r))) (same-parity 1 2 3 4 5 6 7))", "283120332035203729"),
            ("(list (symbol? 'x) (string? \"x\") (boolean? #f) (procedure? +))", "28237420237420237420237429"),
            ("(list (caddr '(1 2 3)) (caadr '(a (b c))))", "2833206229"),
            ("(let ((seen '())) (for-each (lambda (x) (set! seen (cons x seen))) '(1 2 3)) seen)", "28332032203129"),
            ("(assoc '(a b) '(((x) . 1) ((a b) . 2)))", "282861206229202e203229"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            for byte in source.bytes().chain(std::iter::once(b'\r')) { emu.send_key(byte); }
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={expected}");
            let mut matched = false;
            for _ in 0..200 {
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output.lines().any(|line| line.trim_end_matches('\r') == expected_line) {
                    eprintln!("sicp_five source={source} reply={expected_line}");
                    matched = true;
                    break;
                }
            }
            assert!(matched, "no expected reply for {source}: {}", String::from_utf8_lossy(&emu.bus.console_output[start..]));
        }
    }

    // Original roots and bounded exercise candidates use one xy session.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_evaluates_sicp_roots_1_6_to_1_8() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") {
                ready = true;
                break;
            }
        }
        assert!(ready, "guest did not reach xy");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, expected) in [
            ("(begin (define (square x) (* x x)) 601)", "363031"),
            (
                "(begin (define (sqrt-iter guess x) (if (good-enough? guess x) guess (sqrt-iter (improve guess x) x))) 602)",
                "363032",
            ),
            (
                "(begin (define (improve guess x) (average guess (/ x guess))) 603)",
                "363033",
            ),
            ("(begin (define (average x y) (/ (+ x y) 2)) 604)", "363034"),
            (
                "(begin (define (good-enough? guess x) (< (abs (- (square guess) x)) 0.001)) 605)",
                "363035",
            ),
            ("(begin (define (sqrt x) (sqrt-iter 1.0 x)) 606)", "363036"),
            ("(sqrt 9)", "332e3030303039313535343133313338"),
            ("(sqrt 1e-12)", "302e303331323530303030303130363536323534"),
            (
                "(begin (define (sqrt-rel x) (define (loop g) (let ((next (/ (+ g (/ x g)) 2))) (if (< (abs (- next g)) (* 0.000000001 (abs next))) next (loop next)))) (if (= x 0) 0.0 (loop 1.0))) 610)",
                "363130",
            ),
            ("(sqrt-rel 1e-12)", "31652d36"),
            (
                "(sqrt-rel 10000000000000.0)",
                "333136323237372e36363031363833373935",
            ),
            (
                "(begin (define (cube-root x) (define (loop g) (let ((next (/ (+ (/ x (* g g)) (* 2 g)) 3))) (if (< (abs (- next g)) (* 0.000000001 (abs next))) next (loop next)))) (if (= x 0) 0.0 (loop (if (< x 0) -1.0 1.0)))) 611)",
                "363131",
            ),
            ("(cube-root -8)", "2d322e30"),
            ("(cube-root 1e-12)", "302e30303031"),
            (
                "(begin (define (new-if predicate then-clause else-clause) (cond (predicate then-clause) (else else-clause))) 612)",
                "363132",
            ),
            ("(new-if (= 2 3) 0 5)", "35"),
            (
                "(begin (define (sqrt-iter guess x) (new-if (good-enough? guess x) guess (sqrt-iter (improve guess x) x))) 613)",
                "363133",
            ),
            ("(sqrt 9)", "4e657374696e67206c696d6974"),
            ("(+ 20 22)", "3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            for byte in source.bytes().chain(std::iter::once(b'\r')) {
                emu.send_key(byte);
            }
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={expected}");
            let mut matched = false;
            for _ in 0..200 {
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output
                    .lines()
                    .any(|line| line.trim_end_matches('\r') == expected_line)
                {
                    matched = true;
                    eprintln!("sicp_roots source={source} reply={expected_line}");
                    break;
                }
            }
            assert!(
                matched,
                "no expected reply for {source}: {}",
                String::from_utf8_lossy(&emu.bus.console_output[start..])
            );
        }
    }

    // Isolated tree recursion examples, including bounded failures.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_evaluates_sicp_tree_exercise_1_11_1_12() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") {
                ready = true;
                break;
            }
        }
        assert!(ready, "guest did not reach xy");
        let output = String::from_utf8_lossy(&emu.bus.console_output);
        let placement = output
            .lines()
            .find(|line| line.contains("NIHOS_NATIVE_XY_PSRAM "))
            .expect("missing workspace allocation record");
        let field = |name: &str| -> u32 {
            let value = placement
                .split_whitespace()
                .find_map(|part| part.strip_prefix(name))
                .expect("missing workspace allocation field");
            u32::from_str_radix(value, 16).expect("invalid workspace allocation field")
        };
        let address = field("address=");
        let size = field("bytes=");
        let reserved = field("reserved=");
        assert!(
            address >= 0x4820_0000
                && address
                    .checked_add(size)
                    .is_some_and(|end| end <= 0x4a00_0000),
            "{placement}"
        );
        assert!(
            size > 0 && reserved >= size && field("free_after=") > 0,
            "{placement}"
        );
        eprintln!("xy_workspace_placement {placement}");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, expected) in [
            (
                "(begin (define (f-rec n) (if (< n 3) n (+ (f-rec (- n 1)) (* 2 (f-rec (- n 2))) (* 3 (f-rec (- n 3)))))) 801)",
                "383031",
            ),
            ("(f-rec 8)", "333335"),
            ("(f-rec 9)", "373936"),
            ("(+ 20 22)", "3432"),
            (
                "(begin (define (f-it n) (define (go a b c k) (if (= k 0) c (go (+ a (* 2 b) (* 3 c)) a b (- k 1)))) (if (< n 3) n (go 2 1 0 n))) 802)",
                "383032",
            ),
            ("(f-it 20)", "3130373731323131"),
            (
                "(begin (define (pascal row col) (if (or (= col 0) (= col row)) 1 (+ (pascal (- row 1) (- col 1)) (pascal (- row 1) col)))) 803)",
                "383033",
            ),
            ("(pascal 6 3)", "3230"),
            ("(pascal 8 4)", "3730"),
            ("(+ 19 23)", "3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            for byte in source.bytes().chain(std::iter::once(b'\r')) {
                emu.send_key(byte);
            }
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={expected}");
            let mut matched = false;
            for _ in 0..200 {
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output
                    .lines()
                    .any(|line| line.trim_end_matches('\r') == expected_line)
                {
                    matched = true;
                    eprintln!("sicp_tree_exercise_1_11_1_12 source={source} reply={expected_line}");
                    break;
                }
            }
            assert!(
                matched,
                "no expected reply for {source}: {}",
                String::from_utf8_lossy(&emu.bus.console_output[start..])
            );
        }
    }

    // Isolated tree recursion examples, including bounded failures.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_evaluates_sicp_tree_fibonacci() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") {
                ready = true;
                break;
            }
        }
        assert!(ready, "guest did not reach xy");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, expected) in [
            (
                "(begin (define (fib n) (cond ((= n 0) 0) ((= n 1) 1) (else (+ (fib (- n 1)) (fib (- n 2)))))) 811)",
                "383131",
            ),
            ("(fib 9)", "3334"),
            ("(fib 10)", "3535"),
            ("(+ 20 22)", "3432"),
            ("(begin (define (fib n) (fib-iter 1 0 n)) 812)", "383132"),
            (
                "(begin (define (fib-iter a b count) (if (= count 0) b (fib-iter (+ a b) a (- count 1)))) 813)",
                "383133",
            ),
            ("(fib 45)", "31313334393033313730"),
            ("(fib 46)", "496e7465676572206f766572666c6f77"),
            ("(+ 19 23)", "3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            for byte in source.bytes().chain(std::iter::once(b'\r')) {
                emu.send_key(byte);
            }
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={expected}");
            let mut matched = false;
            for _ in 0..200 {
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output
                    .lines()
                    .any(|line| line.trim_end_matches('\r') == expected_line)
                {
                    matched = true;
                    eprintln!("sicp_tree_fibonacci source={source} reply={expected_line}");
                    break;
                }
            }
            assert!(
                matched,
                "no expected reply for {source}: {}",
                String::from_utf8_lossy(&emu.bus.console_output[start..])
            );
        }
    }

    // Isolated tree recursion examples, including bounded failures.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_evaluates_sicp_tree_count_change() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") {
                ready = true;
                break;
            }
        }
        assert!(ready, "guest did not reach xy");
        let output = String::from_utf8_lossy(&emu.bus.console_output);
        let placement = output.lines().find(|line| line.contains("NIHOS_NATIVE_XY_PSRAM ")).expect("missing workspace placement");
        let field = |name: &str| -> u32 {
            u32::from_str_radix(placement.split_whitespace().find_map(|s| s.strip_prefix(name)).expect("missing field"), 16).expect("invalid field")
        };
        let stack_bytes = field("stack_bytes=");
        assert_eq!(stack_bytes, 65536);
        let stack_low = field("address=") + field("bytes=") - stack_bytes;
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, expected) in [
            (
                "(begin (define (count-change amount) (cc amount 5)) 821)",
                "383231",
            ),
            (
                "(begin (define (cc amount kinds-of-coins) (cond ((= amount 0) 1) ((or (< amount 0) (= kinds-of-coins 0)) 0) (else (+ (cc amount (- kinds-of-coins 1)) (cc (- amount (first-denomination kinds-of-coins)) kinds-of-coins))))) 822)",
                "383232",
            ),
            (
                "(begin (define (first-denomination kinds-of-coins) (cond ((= kinds-of-coins 1) 1) ((= kinds-of-coins 2) 5) ((= kinds-of-coins 3) 10) ((= kinds-of-coins 4) 25) ((= kinds-of-coins 5) 50))) 823)",
                "383233",
            ),
            ("(count-change 10)", "34"),
            ("(count-change 100)", "4e657374696e67206c696d6974"),
            ("(+ 20 22)", "3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            for byte in source.bytes().chain(std::iter::once(b'\r')) {
                emu.send_key(byte);
            }
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={expected}");
            let mut matched = false;
            for _ in 0..200 {
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output
                    .lines()
                    .any(|line| line.trim_end_matches('\r') == expected_line)
                {
                    matched = true;
                    eprintln!("sicp_tree_count_change source={source} reply={expected_line}");
                    break;
                }
            }
            assert!(
                matched,
                "no expected reply for {source}: {}",
                String::from_utf8_lossy(&emu.bus.console_output[start..])
            );
            if source == "(count-change 100)" {
                // The guest paints this stack with 0xa5 before each evaluation.
                // Wait beyond the reply so its foreground call has returned.
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let first = (256..stack_bytes).find(|i| {
                    let offset = emu.bus.translate_psram(stack_low + i);
                    emu.bus.psram[offset] != 0xa5
                }).unwrap_or(stack_bytes);
                let used = stack_bytes - first;
                assert!((0..256).all(|i| emu.bus.psram[emu.bus.translate_psram(stack_low + i)] == 0xa5), "stack guard changed");
                assert!(used > 0, "invalid stack watermark");
                eprintln!("sicp_stack_watermark source={source} low={stack_low:#x} bytes={stack_bytes} observed_used={used}");
            }
        }
    }

    // Pascal evaluation in a fresh xy session.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_evaluates_sicp_tree_pascal_fresh() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") {
                ready = true;
                break;
            }
        }
        assert!(ready, "guest did not reach xy");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, expected) in [
            (
                "(begin (define (pascal row col) (if (or (= col 0) (= col row)) 1 (+ (pascal (- row 1) (- col 1)) (pascal (- row 1) col)))) 831)",
                "383331",
            ),
            ("(pascal 8 4)", "3730"),
            ("(+ 20 22)", "3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            for byte in source.bytes().chain(std::iter::once(b'\r')) {
                emu.send_key(byte);
            }
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={expected}");
            let mut matched = false;
            for _ in 0..200 {
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output
                    .lines()
                    .any(|line| line.trim_end_matches('\r') == expected_line)
                {
                    matched = true;
                    eprintln!("sicp_tree_pascal_fresh source={source} reply={expected_line}");
                    break;
                }
            }
            assert!(
                matched,
                "no expected reply for {source}: {}",
                String::from_utf8_lossy(&emu.bus.console_output[start..])
            );
        }
    }

    // Original recursion examples run in an isolated xy session.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_evaluates_sicp_recursion_1_9_1_10() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        let mut ready = false;
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if output.contains("NIHOS_NATIVE_XY_READY") {
                ready = true;
                break;
            }
        }
        assert!(ready, "guest did not reach xy");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, expected) in [
            ("(begin (define (inc x) (- x -1)) 701)", "373031"),
            ("(begin (define (dec x) (- x 1)) 702)", "373032"),
            (
                "(begin (define (+ a b) (if (= a 0) b (inc (+ (dec a) b)))) 703)",
                "373033",
            ),
            ("(+ 4 5)", "39"),
            ("(+ 30 5)", "4e657374696e67206c696d6974"),
            ("(+ 4 5)", "39"),
            (
                "(begin (define (+ a b) (if (= a 0) b (+ (dec a) (inc b)))) 704)",
                "373034",
            ),
            ("(+ 150 5)", "313535"),
            (
                "(begin (define (A x y) (cond ((= y 0) 0) ((= x 0) (* 2 y)) ((= y 1) 2) (else (A (- x 1) (A x (- y 1)))))) 705)",
                "373035",
            ),
            ("(A 1 10)", "31303234"),
            ("(A 2 4)", "3635353336"),
            ("(A 0 5)", "3130"),
            ("(A 3 3)", "3635353336"),
            ("(- 44 2)", "3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            for byte in source.bytes().chain(std::iter::once(b'\r')) {
                emu.send_key(byte);
            }
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={expected}");
            let mut matched = false;
            for _ in 0..200 {
                emu.step_frame(5_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output
                    .lines()
                    .any(|line| line.trim_end_matches('\r') == expected_line)
                {
                    matched = true;
                    eprintln!("sicp_recursion source={source} reply={expected_line}");
                    break;
                }
            }
            assert!(
                matched,
                "no expected reply for {source}: {}",
                String::from_utf8_lossy(&emu.bus.console_output[start..])
            );
        }
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
