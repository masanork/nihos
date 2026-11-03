//! High-level nihos RV32 Target Emulator for GPUI.

pub mod bus;
pub mod cpu;
pub mod elf;
#[cfg(any(test, feature = "experimental-meos"))]
mod esp_image;
#[cfg(any(test, feature = "experimental-meos"))]
mod rom_flash;
mod rom_printf;
mod rom_psram;
mod rom_qsort;
mod rom_systimer;
mod rom_wdt;
mod tab5_i2c;
#[cfg(any(test, feature = "experimental-meos"))]
mod usb_dwc;

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
    #[cfg(feature = "experimental-meos")]
    meos_rom: Option<PathBuf>,
    #[cfg(test)]
    gc_probe: Option<GcInstructionProbe>,
}

impl Emulator {
    #[cfg(test)]
    pub(crate) fn empty_for_display_test() -> Self {
        Self {
            bus: Bus::new(),
            cpu: Cpu::new(bus::SRAM_BASE),
            cpu1: None,
            elf_path: PathBuf::new(),
            dict_path: None,
            paused: false,
            total_steps: 0,
            mips: 0.0,
            #[cfg(feature = "experimental-meos")]
            meos_rom: None,
            gc_probe: None,
        }
    }

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
            #[cfg(feature = "experimental-meos")]
            meos_rom: None,
            #[cfg(test)]
            gc_probe: None,
        })
    }

    /// A pinned, synthetic direct-app fixture, not an ESP bootloader or persistent device.
    #[cfg(feature = "experimental-meos")]
    pub fn new_meos(app: impl AsRef<Path>, rom: impl AsRef<Path>) -> std::io::Result<Self> {
        use sha2::{Digest, Sha256};
        use std::io::{Error, ErrorKind};
        fn check(path: &Path, expected: &str) -> std::io::Result<()> {
            let digest = format!("{:x}", Sha256::digest(std::fs::read(path)?));
            if digest != expected {
                return Err(Error::new(
                    ErrorKind::InvalidData,
                    format!("unsupported experimental MeOS fixture: {}", path.display()),
                ));
            }
            Ok(())
        }
        let app = app.as_ref().to_path_buf();
        let rom = rom.as_ref().to_path_buf();
        check(
            &app,
            "2802acccea64410dee3e0caea5fd683d499a84b5818d76682580730ee7a1f09a",
        )?;
        check(
            &rom,
            "948f2c7d108d04a9c3a982f9c1c498fb17f2c4a68abc51f87782592034d7ce44",
        )?;
        let mut bus = Bus::new();
        bus.use_st7121_fixture();
        let mut flash = rom_flash::Flash::erased();
        flash.blank_dictionary = true;
        bus.rom_flash = Some(flash);
        bus.usb_dwc = Some(usb_dwc::Usb::new());
        let entry = esp_image::load(&mut bus, &app)?;
        esp_image::load_rom_data(&mut bus, &rom, 0x4fc1_d780)?;
        bus.rom_execute = true;
        bus.write_u32(0x5011_003c, 0x0028_0028);
        let clock = bus.read_u32(0x500e_6030);
        bus.write_u32(0x500e_6030, (clock & !0xfff) | 0x5d);
        Ok(Self {
            bus,
            cpu: Cpu::new(entry),
            cpu1: None,
            elf_path: app,
            dict_path: None,
            paused: false,
            total_steps: 0,
            mips: 0.0,
            meos_rom: Some(rom),
            #[cfg(test)]
            gc_probe: None,
        })
    }

    #[cfg(feature = "experimental-meos")]
    pub fn is_meos_fixture(&self) -> bool {
        self.meos_rom.is_some()
    }

    pub fn fault(&self) -> Option<&str> {
        self.cpu
            .fault
            .as_deref()
            .or_else(|| self.cpu1.as_ref().and_then(|cpu| cpu.fault.as_deref()))
    }

    /// Reset CPU and reload memory from ELF and dictionary.
    pub fn reset(&mut self) -> std::io::Result<()> {
        #[cfg(feature = "experimental-meos")]
        if let Some(rom) = &self.meos_rom {
            let mut fresh = Self::new_meos(&self.elf_path, rom)?;
            fresh.paused = self.paused;
            *self = fresh;
            return Ok(());
        }
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
        {
            self.gc_probe = None;
        }
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
            let p565 = self.bus.scanout().map_or(0, |frame| {
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

    #[cfg(feature = "experimental-meos")]
    #[test]
    fn experimental_meos_profile_rejects_unknown_image() {
        let error = match Emulator::new_meos("/dev/null", "/dev/null") {
            Ok(_) => panic!("unexpectedly accepted an unknown image"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    }

    #[cfg(feature = "experimental-meos")]
    #[test]
    #[ignore = "requires the pinned MeOS app and ROM"]
    fn experimental_meos_osk_touch_reaches_shell() {
        let app = std::env::var_os("NIHOS_EMU_ESP_APP").expect("set NIHOS_EMU_ESP_APP");
        let rom = std::env::var_os("NIHOS_EMU_ROM_ELF").expect("set NIHOS_EMU_ROM_ELF");
        let mut emu = Emulator::new_meos(app, rom).unwrap();
        for _ in 0..800 {
            emu.step_frame(500_000);
            assert!(emu.fault().is_none(), "guest fault: {:?}", emu.fault());
            if emu.bus.console_output.windows(4).any(|w| w == b"\r\n> ")
                && emu
                    .bus
                    .console_output
                    .windows(18)
                    .any(|w| w == b"using the built-in")
            {
                break;
            }
        }
        assert!(
            emu.bus
                .console_output
                .windows(18)
                .any(|w| w == b"using the built-in")
        );
        // Drain asynchronous startup messages before checking the input echo.
        emu.step_frame(50_000_000);
        assert!(emu.fault().is_none(), "guest fault: {:?}", emu.fault());
        let before = emu.bus.console_output.len();
        // MeOS map 1 transforms physical (575, 719) to the centre of the
        // landscape on-screen keyboard's h key (560, 575).
        emu.bus.touch(Some((575, 719)));
        emu.bus.touch(None);
        for _ in 0..400 {
            emu.step_frame(500_000);
            assert!(emu.fault().is_none(), "guest fault: {:?}", emu.fault());
            if !emu.bus.console_output[before..].is_empty() {
                assert_eq!(&emu.bus.console_output[before..], b"h");
                println!(
                    "on-screen h echo: {:?}",
                    String::from_utf8_lossy(&emu.bus.console_output[before..])
                );
                return;
            }
        }
        panic!(
            "guest did not echo on-screen h: {:?}",
            String::from_utf8_lossy(&emu.bus.console_output[before..])
        );
    }

    #[cfg(feature = "experimental-meos")]
    #[test]
    #[ignore = "requires the pinned MeOS app and ROM"]
    fn experimental_meos_profile_boot_and_reset() {
        let app = std::env::var_os("NIHOS_EMU_ESP_APP").expect("set NIHOS_EMU_ESP_APP");
        let rom = std::env::var_os("NIHOS_EMU_ROM_ELF").expect("set NIHOS_EMU_ROM_ELF");
        let mut emu = Emulator::new_meos(app, rom).unwrap();
        for _ in 0..600 {
            emu.step_frame(500_000);
            assert!(emu.fault().is_none(), "guest fault: {:?}", emu.fault());
            if emu.bus.console_output.windows(4).any(|w| w == b"\r\n> ") {
                break;
            }
        }
        assert!(
            emu.bus.console_output.windows(4).any(|w| w == b"\r\n> "),
            "MeOS prompt not reached"
        );
        assert!(emu.bus.scanout_frames > 1);
        for byte in b"run /apps/snake.wasm\n" {
            emu.send_key(*byte);
        }
        for _ in 0..600 {
            emu.step_frame(500_000);
            assert!(emu.fault().is_none(), "guest fault: {:?}", emu.fault());
            if emu.bus.console_output.windows(7).any(|w| w == b"started") {
                break;
            }
        }
        assert!(emu.bus.console_output.windows(7).any(|w| w == b"started"));
        super::super::send_emulator_arrow(&mut emu, "down");
        assert!(emu.bus.keyboard_fifo.ends_with(b"\x1b[B"));
        for _ in 0..1000 {
            emu.step_frame(500_000);
            assert!(
                emu.fault().is_none(),
                "guest fault: {:?}, pc={:#x}, args={:x?}",
                emu.fault(),
                emu.cpu.pc,
                &emu.cpu.x[10..14]
            );
        }
        emu.paused = true;
        emu.send_key(b'!');
        let steps = emu.total_steps;
        let pc = emu.cpu.pc;
        let app_path = std::mem::replace(&mut emu.elf_path, PathBuf::from("/dev/null"));
        assert!(emu.reset().is_err());
        assert!(emu.paused && emu.is_meos_fixture());
        assert_eq!(emu.total_steps, steps);
        assert_eq!(emu.cpu.pc, pc);
        assert!(emu.bus.keyboard_fifo.ends_with(b"!"));
        emu.elf_path = app_path;
        emu.reset().unwrap();
        assert!(emu.is_meos_fixture());
        assert!(emu.paused);
        assert_eq!(emu.total_steps, 0);
        assert!(emu.bus.keyboard_fifo.is_empty());
        assert_eq!(emu.bus.scanout_frames, 0);
    }

    #[test]
    fn framebuffer_uses_display_base_and_mmu_mapping() {
        let mut bus = Bus::new();
        bus.psram[0] = 17;
        bus.write_u8(bus::FB_BASE, 42);
        assert_eq!(bus.framebuffer_byte(0), Some(42));
        bus.mmu_table[3] = 7;
        bus.psram[7 * 65536] = 99;
        assert_eq!(bus.framebuffer_byte(0), Some(99));
    }

    #[test]
    fn uncached_internal_sram_alias_shares_data_and_is_bounded() {
        let mut bus = Bus::new();
        let cached = bus::SRAM_BASE + 0x13c80;
        let alias = bus::SRAM_UNCACHED_BASE + 0x13c80;
        bus.write_u32(alias + 1, 0x1234_5678);
        assert_eq!(bus.read_u32(cached + 1), 0x1234_5678);
        bus.write_u16(cached + 2, 0xabcd);
        assert_eq!(bus.read_u32(alias + 1), 0x12ab_cd78);
        let last = bus::SRAM_UNCACHED_BASE + bus::SRAM_UNCACHED_SIZE as u32 - 1;
        bus.write_u16(last, 0xbbaa);
        assert_eq!(bus.read_u8(last), 0xaa);
        assert_eq!(bus.read_u8(last + 1), 0);
        assert_eq!(
            bus.read_u8(bus::SRAM_BASE + bus::SRAM_UNCACHED_SIZE as u32),
            0
        );
    }

    #[test]
    fn dma_reads_descriptors_written_through_uncached_alias() {
        let mut bus = Bus::new();
        let desc = 0x4ff1_3c80;
        let alias = desc + 0x4000_0000;
        bus.write_u32(bus::FB_BASE, 0xf800_f800);
        bus.write_u32(bus::FB_BASE + 4, 0xf800_f800);
        bus.write_u32(alias, bus::FB_BASE);
        bus.write_u32(alias + 8, 0x5010_5000);
        bus.write_u32(alias + 16, (bus::FB_SIZE / 8 - 1) as u32);
        bus.write_u32(alias + 32, 0x310);
        bus.write_u32(alias + 36, 0xc000_0000);
        bus.write_u32(0x5008_1128, desc);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!(bus.scanout_frames, 1);
        assert_eq!(&bus.scanout().unwrap()[..4], &[0, 0xf8, 0, 0xf8]);
    }

    #[test]
    fn identical_dma_preserves_completion_but_does_not_change_pixels_revision() {
        let mut bus = Bus::new();
        let desc = 0x4ff1_0000;
        bus.write_u32(bus::FB_BASE, 0xf800_f800);
        bus.write_u32(bus::FB_BASE + 4, 0xf800_f800);
        bus.write_u32(desc, bus::FB_BASE);
        bus.write_u32(desc + 8, 0x5010_5000);
        bus.write_u32(desc + 16, (bus::FB_SIZE / 8 - 1) as u32);
        bus.write_u32(desc + 32, 0x310);
        bus.write_u32(desc + 36, 0xc000_0000);
        bus.write_u32(0x5008_1128, desc);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (1, 1));
        bus.timer_ticks += 1_000_000;
        assert_eq!(bus.read_u32(0x5008_1188), 2);
        bus.write_u32(0x5008_1198, 2);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (2, 1));
        assert_eq!(bus.read_u32(0x5008_1188), 0);
        bus.timer_ticks += 1_000_000;
        assert_eq!(bus.read_u32(0x5008_1188), 2);
        bus.write_u32(bus::FB_BASE, 0x001f_001f);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (3, 2));
        assert_eq!(&bus.scanout().unwrap()[..4], &[0x1f, 0, 0x1f, 0]);
        bus.write_u32(0x5008_1198, 2);
        bus.write_u32(0x5008_e380, 3);
        bus.write_u32(0x5008_e37c, 0);
        bus.write_u32(0x5008_1018, 0x101);
        bus.timer_ticks += 1_000_000;
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (3, 2));
        assert_eq!(bus.read_u32(0x5008_1188), 0);
    }

    #[test]
    fn nonfixed_dma_replaces_cached_fixed_pattern() {
        let mut bus = Bus::new();
        let desc = 0x4ff1_0000;
        let offset = (bus::FB_BASE - bus::PSRAM_BASE) as usize;
        for pixel in bus.psram[offset..offset + bus::FB_SIZE].chunks_exact_mut(2) {
            pixel.copy_from_slice(&[0xe0, 0x07]);
        }
        bus.write_u32(bus::FB_BASE, 0x001f_001f);
        bus.write_u32(bus::FB_BASE + 4, 0x001f_001f);
        bus.write_u32(desc, bus::FB_BASE);
        bus.write_u32(desc + 8, 0x5010_5000);
        bus.write_u32(desc + 16, (bus::FB_SIZE / 8 - 1) as u32);
        bus.write_u32(desc + 32, 0x310);
        bus.write_u32(desc + 36, 0xc000_0000);
        bus.write_u32(0x5008_1128, desc);
        bus.write_u32(0x5008_1018, 0x101);
        bus.write_u32(desc + 32, 0x300);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!(&bus.scanout().unwrap()[8..10], &[0xe0, 0x07]);
        bus.write_u32(desc + 32, 0x310);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (3, 3));
        assert_eq!(&bus.scanout().unwrap()[8..10], &[0x1f, 0]);
    }

    #[test]
    fn nonfixed_dma_defers_publication_until_all_pages_validate() {
        let mut bus = Bus::new();
        let desc = 0x4ff1_0000;
        let src = bus::FB_BASE + 1;
        let offset = (src - bus::PSRAM_BASE) as usize;
        bus.psram[offset..offset + bus::FB_SIZE].fill(0x55);
        bus.write_u32(desc, src);
        bus.write_u32(desc + 8, 0x5010_5000);
        bus.write_u32(desc + 16, (bus::FB_SIZE / 8 - 1) as u32);
        bus.write_u32(desc + 32, 0x300);
        bus.write_u32(desc + 36, 0xc000_0000);
        bus.write_u32(0x5008_1128, desc);
        bus.write_u32(0x5008_1018, 0x101);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (2, 1));
        bus.psram[offset + bus::FB_SIZE - 1] = 0xaa;
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (3, 2));
        assert_eq!(bus.scanout().unwrap()[bus::FB_SIZE - 1], 0xaa);
        let previous = bus.scanout().map(<[u8]>::to_vec);
        bus.psram[offset] = 0xcc;
        bus.write_u32(0x5008_e380, 4);
        bus.write_u32(0x5008_e37c, 0);
        bus.write_u32(0x5008_1018, 0x101);
        bus.timer_ticks += 1_000_000;
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (3, 2));
        assert_eq!(bus.scanout(), previous.as_deref());
        assert_eq!(bus.read_u32(0x5008_1188), 0);
    }

    #[test]
    fn dma_rejects_suspended_cache_for_fixed_and_nonfixed_sources() {
        for control in [0x300, 0x310] {
            let mut bus = Bus::new();
            let desc = 0x4ff1_0000;
            bus.write_u32(desc, bus::FB_BASE);
            bus.write_u32(desc + 8, 0x5010_5000);
            bus.write_u32(desc + 16, (bus::FB_SIZE / 8 - 1) as u32);
            bus.write_u32(desc + 32, control);
            bus.write_u32(desc + 36, 0xc000_0000);
            bus.write_u32(0x5008_1128, desc);
            bus.write_u32(0x5008_1018, 0x101);
            assert_eq!((bus.scanout_frames, bus.scanout_revision()), (1, 1));
            bus.timer_ticks += 1_000_000;
            assert_eq!(bus.read_u32(0x5008_1188), 2);
            bus.write_u32(0x5008_1198, 2);
            bus.psram[(bus::FB_BASE - bus::PSRAM_BASE) as usize] = 0x42;
            bus.cache_l2_suspended = true;
            bus.write_u32(0x5008_1018, 0x101);
            bus.timer_ticks += 1_000_000;
            assert_eq!((bus.scanout_frames, bus.scanout_revision()), (1, 1));
            assert_eq!(bus.scanout().unwrap()[0], 0);
            assert_eq!(bus.read_u32(0x5008_1188), 0);
            bus.cache_l2_suspended = false;
            bus.write_u32(0x5008_1018, 0x101);
            assert_eq!((bus.scanout_frames, bus.scanout_revision()), (2, 2));
            assert_eq!(bus.scanout().unwrap()[0], 0x42);
            bus.timer_ticks += 1_000_000;
            assert_eq!(bus.read_u32(0x5008_1188), 2);
        }
    }

    #[test]
    fn fixed_dma_uses_current_psram_mapping_before_reusing_frame() {
        let mut bus = Bus::new();
        let desc = 0x4ff1_0000;
        bus.write_u32(desc, bus::FB_BASE);
        bus.write_u32(desc + 8, 0x5010_5000);
        bus.write_u32(desc + 16, (bus::FB_SIZE / 8 - 1) as u32);
        bus.write_u32(desc + 32, 0x310);
        bus.write_u32(desc + 36, 0xc000_0000);
        bus.write_u32(0x5008_1128, desc);
        bus.write_u32(0x5008_1018, 0x101);
        bus.write_u32(0x5008_e380, 3);
        bus.write_u32(0x5008_e37c, 0xc00 | 7);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (2, 1));
        bus.psram[7 * 65536] = 0x33;
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (3, 2));
        assert_eq!(bus.scanout().unwrap()[0], 0x33);
    }

    #[test]
    #[ignore = "manual fixed-pattern DMA microbenchmark"]
    fn benchmark_duplicate_fixed_dma() {
        let mut bus = Bus::new();
        let desc = 0x4ff1_0000;
        bus.write_u32(bus::FB_BASE, 0xf800_f800);
        bus.write_u32(bus::FB_BASE + 4, 0xf800_f800);
        bus.write_u32(desc, bus::FB_BASE);
        bus.write_u32(desc + 8, 0x5010_5000);
        bus.write_u32(desc + 16, (bus::FB_SIZE / 8 - 1) as u32);
        bus.write_u32(desc + 32, 0x310);
        bus.write_u32(desc + 36, 0xc000_0000);
        bus.write_u32(0x5008_1128, desc);
        bus.write_u32(0x5008_1018, 0x101);
        for _ in 0..3 {
            let start = std::time::Instant::now();
            for _ in 0..20 {
                bus.write_u32(0x5008_1018, 0x101);
            }
            eprintln!("20 duplicate fixed DMA transfers: {:?}", start.elapsed());
        }
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (61, 1));
    }

    #[test]
    #[ignore = "manual non-fixed DMA microbenchmark"]
    fn benchmark_duplicate_nonfixed_dma() {
        let mut bus = Bus::new();
        let desc = 0x4ff1_0000;
        let offset = (bus::FB_BASE - bus::PSRAM_BASE) as usize;
        bus.psram[offset..offset + bus::FB_SIZE].fill(0xa5);
        bus.write_u32(desc, bus::FB_BASE);
        bus.write_u32(desc + 8, 0x5010_5000);
        bus.write_u32(desc + 16, (bus::FB_SIZE / 8 - 1) as u32);
        bus.write_u32(desc + 32, 0x300);
        bus.write_u32(desc + 36, 0xc000_0000);
        bus.write_u32(0x5008_1128, desc);
        bus.write_u32(0x5008_1018, 0x101);
        for _ in 0..3 {
            let start = std::time::Instant::now();
            for _ in 0..20 {
                bus.write_u32(0x5008_1018, 0x101);
            }
            eprintln!(
                "20 duplicate non-fixed DMA transfers: {:?}",
                start.elapsed()
            );
        }
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (61, 1));
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
        assert!(bus.scanout().is_none());
        assert_eq!(bus.read_u32(0x5008_1188), 0);
        bus.write_u8(bus::FB_BASE, 0xab);
        bus.write_u32(desc + 36, 0xc000_0000);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!(bus.scanout().unwrap()[0], 0xab);
        bus.timer_ticks += 1_000_000;
        assert_eq!(bus.read_u32(0x5008_1188), 2);
        bus.write_u8(bus::FB_BASE, 0xcd);
        assert_eq!(bus.scanout().unwrap()[0], 0xab);
        bus.write_u32(0x5008_1198, 2);
        assert_eq!(bus.read_u32(0x5008_1188), 0);
        bus.write_u32(0x5008_e380, 4);
        bus.write_u32(0x5008_e37c, 0);
        let previous_frames = bus.scanout_frames;
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!(bus.scanout_frames, previous_frames);
        assert_eq!(bus.scanout().unwrap()[0], 0xab);
        assert_eq!(bus.read_u32(0x5008_1188), 0);
    }

    #[test]
    fn dma_software_reset_clears_modeled_state_and_self_clears() {
        let mut bus = Bus::new();
        let desc = 0x4ff1_0000;
        bus.write_u32(desc, bus::FB_BASE);
        bus.write_u32(desc + 8, 0x5010_5000);
        bus.write_u32(desc + 16, (bus::FB_SIZE / 8 - 1) as u32);
        bus.write_u32(desc + 32, 0x310);
        bus.write_u32(desc + 36, 0xc000_0000);
        bus.write_u32(0x5008_1128, desc);
        bus.write_u32(0x5008_1018, 0x101);
        bus.timer_ticks += 1_000_000;
        assert_eq!(bus.read_u32(0x5008_1188), 2);
        let frame = bus.scanout().unwrap().to_vec();
        bus.write_u32(0x5008_1058, 0);
        assert_eq!(bus.read_u32(0x5008_1128), desc);
        bus.write_u32(0x5008_1058, 1);
        assert_eq!(bus.read_u32(0x5008_1058) & 1, 0);
        assert_eq!(bus.read_u32(0x5008_1128), 0);
        assert_eq!(bus.read_u32(0x5008_1188), 0);
        assert_eq!(bus.read_u32(0x500a_0814), 0);
        assert_eq!(bus.scanout(), Some(frame.as_slice()));
        assert_eq!((bus.scanout_frames, bus.scanout_revision()), (1, 1));
    }

    #[test]
    fn dma_global_status_and_interrupt_follow_masks_and_matrix_route() {
        let mut bus = Bus::new();
        let desc = 0x4ff1_0000;
        bus.write_u32(desc, bus::FB_BASE);
        bus.write_u32(desc + 8, 0x5010_5000);
        bus.write_u32(desc + 16, (bus::FB_SIZE / 8 - 1) as u32);
        bus.write_u32(desc + 32, 0x310);
        bus.write_u32(desc + 36, 0xc000_0000);
        bus.write_u32(0x5008_1128, desc);
        bus.write_u32(0x5008_1010, 3);
        bus.write_u32(0x5008_1190, 2);
        bus.write_u8(0x2080_1000 + 23 * 4 + 1, 1);
        bus.write_u32(0x5008_1018, 0x101);
        assert_eq!(bus.read_u32(0x5008_1030), 0);
        bus.timer_ticks += 1_000_000;
        assert_eq!(bus.read_u32(0x5008_1030), 1);
        assert_eq!(bus.pending_irq(0), None); // not routed
        bus.write_u32(0x500d_6000 + 24 * 4, 23);
        assert_eq!(bus.pending_irq(0), Some(23));
        assert_eq!(bus.pending_irq(1), None);
        bus.write_u32(0x5008_1010, 1); // global interrupt disabled
        assert_eq!(bus.pending_irq(0), None);
        bus.write_u32(0x5008_1010, 3);
        bus.write_u32(0x5008_1190, 0); // channel propagation disabled
        assert_eq!(bus.read_u32(0x5008_1030), 0);
        assert_eq!(bus.pending_irq(0), None);
        bus.write_u32(0x5008_1190, 2);
        bus.write_u32(0x5008_1198, 2);
        assert_eq!(bus.read_u32(0x5008_1030), 0);
        assert_eq!(bus.pending_irq(0), None);
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
    fn gpio_bitbang_reaches_both_board_expanders() {
        fn lines(bus: &mut Bus, scl: bool, sda: bool) {
            bus.write_u32(if scl { 0x500e_0034 } else { 0x500e_0030 }, 1);
            bus.write_u32(if sda { 0x500e_0028 } else { 0x500e_0024 }, 1 << 31);
        }
        fn start(bus: &mut Bus) {
            lines(bus, true, true);
            lines(bus, true, false);
            lines(bus, false, false);
        }
        fn stop(bus: &mut Bus) {
            lines(bus, false, false);
            lines(bus, true, false);
            lines(bus, true, true);
        }
        fn byte(bus: &mut Bus, value: u8) -> bool {
            for bit in (0..8).rev() {
                let high = value & (1 << bit) != 0;
                lines(bus, false, high);
                lines(bus, true, high);
                lines(bus, false, high);
            }
            lines(bus, false, true);
            lines(bus, true, true);
            let acknowledged = bus.read_u32(0x500e_003c) & (1 << 31) == 0;
            lines(bus, false, true);
            acknowledged
        }
        let mut bus = Bus::new();
        for address in [0x43, 0x44] {
            start(&mut bus);
            assert!(byte(&mut bus, address << 1));
            assert!(byte(&mut bus, 5));
            assert!(byte(&mut bus, address));
            stop(&mut bus);
        }
        start(&mut bus);
        assert!(!byte(&mut bus, 0x45 << 1));
        stop(&mut bus);
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
    fn pending_interrupt_does_not_reenter_before_mret() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4ff0_0100);
        cpu.mstatus |= 8;
        cpu.mtvt = 0x4ff0_0200;
        bus.write_u32(cpu.mtvt + 17 * 4, 0x4ff0_0400);
        bus.write_u32(0x4ff0_0400, 0x3004_6073); // csrsi mstatus, 8
        bus.write_u32(0x4ff0_0404, 0x0070_0513); // addi a0, zero, 7
        bus.write_u32(0x4ff0_0408, 0x3020_0073); // mret
        bus.write_u32(0x500d_6000 + 79 * 4, 17);
        bus.write_u8(0x2080_1000 + 17 * 4 + 1, 1);
        bus.write_u8(0x2080_1000 + 17 * 4 + 2, 1);
        bus.write_u32(0x500e_5010, 1);
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.pc, 0x4ff0_0404);
        assert_ne!(cpu.mstatus & 8, 0);
        cpu.instructions_executed = 64;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 7);
        assert_eq!(cpu.mepc, 0x4ff0_0100);
        cpu.instructions_executed = 128;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.pc, 0x4ff0_0100);
        cpu.instructions_executed = 192;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.pc, 0x4ff0_0404);
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
        let mut illegal = Cpu::new(0x4ff0_3000);
        bus.write_u16(illegal.pc, 0);
        assert!(!illegal.step(&mut bus));
        assert!(illegal.fault.unwrap().contains("0x4ff03000"));
        let mut rom = Cpu::new(0x4fc0_1234);
        assert!(!rom.step(&mut bus));
        assert!(rom.fault.as_deref().unwrap().contains("0x4fc01234"));
    }

    #[test]
    fn fcvt_s_wu_rounds_all_modes_and_accumulates_inexact() {
        let mut bus = Bus::new();
        let pc = 0x4ff0_1000;
        bus.write_u32(pc, 0xd017_f7d3); // fcvt.s.wu f15, x15, dynamic
        for (value, mode, expected, inexact) in [
            (0, 0, 0.0f32, false),
            (16_777_216, 0, 16_777_216.0, false),
            (16_777_217, 0, 16_777_216.0, true),
            (16_777_219, 0, 16_777_220.0, true),
            (16_777_217, 1, 16_777_216.0, true),
            (16_777_217, 2, 16_777_216.0, true),
            (16_777_217, 3, 16_777_218.0, true),
            (16_777_217, 4, 16_777_218.0, true),
            (u32::MAX, 1, 4_294_967_040.0, true),
            (u32::MAX, 3, 4_294_967_296.0, true),
        ] {
            let mut cpu = Cpu::new(pc);
            cpu.x[15] = value;
            cpu.fcsr = mode << 5 | 0x10;
            assert!(cpu.step(&mut bus));
            assert_eq!(
                cpu.f[15].to_bits(),
                expected.to_bits(),
                "value={value} mode={mode}"
            );
            assert_eq!(cpu.fcsr, mode << 5 | 0x10 | u32::from(inexact));
        }
        let mut invalid = Cpu::new(pc);
        invalid.x[15] = 42;
        invalid.f[15] = 3.0;
        invalid.fcsr = 5 << 5;
        assert!(!invalid.step(&mut bus));
        assert_eq!(invalid.f[15], 3.0);
        assert_eq!(invalid.fcsr, 5 << 5);
        assert!(invalid.fault.unwrap().contains("rounding mode"));
    }

    #[test]
    fn floating_point_csrs_share_rounding_and_flag_bits() {
        let mut bus = Bus::new();
        let pc = 0x4ff0_1000;
        bus.write_u32(pc, 0x0030_9073); // csrrw x0, fcsr, x1
        bus.write_u32(pc + 4, 0x0010_2173); // csrrs x2, fflags, x0
        bus.write_u32(pc + 8, 0x0020_21f3); // csrrs x3, frm, x0
        let mut cpu = Cpu::new(pc);
        cpu.x[1] = 0xffff_ffff;
        assert!(cpu.step(&mut bus));
        assert!(cpu.step(&mut bus));
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.fcsr, 0xff);
        assert_eq!(cpu.x[2], 0x1f);
        assert_eq!(cpu.x[3], 7);
    }

    #[test]
    fn fcvt_s_wu_nearest_matches_host_conversion_corpus() {
        let mut bus = Bus::new();
        let pc = 0x4ff0_1000;
        bus.write_u32(pc, 0xd017_f7d3);
        let mut cpu = Cpu::new(pc);
        let mut value = 0x1234_5678u32;
        for _ in 0..10_000 {
            value = value.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            cpu.pc = pc;
            cpu.x[15] = value;
            cpu.fcsr = 0;
            assert!(cpu.step(&mut bus));
            let expected = value as f32;
            assert_eq!(cpu.f[15].to_bits(), expected.to_bits(), "value={value}");
            assert_eq!(cpu.fcsr, u32::from(expected as u64 != u64::from(value)));
        }
    }

    #[test]
    fn fcvt_wu_s_rounding_clipping_and_sticky_flags() {
        let mut bus = Bus::new();
        let pc = 0x4ff0_1000;
        // fcvt.wu.s x3, f1, dynamic
        bus.write_u32(
            pc,
            (0x60 << 25) | (1 << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x53,
        );
        for (source, mode, expected, flags) in [
            (0x0000_0000, 0, 0, 0),
            (0x8000_0000, 0, 0, 0),
            (0x3fc0_0000, 0, 2, 1), // 1.5, ties to even
            (0x4020_0000, 0, 2, 1), // 2.5, ties to even
            (0x4020_0000, 1, 2, 1),
            (0x4020_0000, 2, 2, 1),
            (0x4020_0000, 3, 3, 1),
            (0x4020_0000, 4, 3, 1),
            (0xbf00_0000, 0, 0, 1), // -0.5 rounds to zero
            (0xbf00_0000, 2, 0, 16),
            (0xbf00_0000, 4, 0, 16),
            (0xbf80_0000, 1, 0, 16),
            (0x4f7f_ffff, 0, 0xffff_ff00, 0),
            (0x4f80_0000, 0, u32::MAX, 16),
            (0x7f80_0000, 0, u32::MAX, 16),
            (0xff80_0000, 0, 0, 16),
            (0x7fc0_1234, 0, u32::MAX, 16),
            (0xff80_1234, 0, u32::MAX, 16),
        ] {
            let mut cpu = Cpu::new(pc);
            cpu.f[1] = f32::from_bits(source);
            cpu.fcsr = (mode << 5) | 8;
            assert!(cpu.step(&mut bus));
            assert_eq!(cpu.x[3], expected, "source={source:x} mode={mode}");
            assert_eq!(cpu.fcsr, (mode << 5) | 8 | flags);
        }
        let mut cpu = Cpu::new(pc);
        cpu.f[1] = 2.5;
        cpu.x[3] = 17;
        cpu.fcsr = 5 << 5;
        assert!(!cpu.step(&mut bus));
        assert_eq!(cpu.x[3], 17);
        assert_eq!(cpu.fcsr, 5 << 5);
    }

    #[test]
    fn fdiv_s_rounding_nan_and_exception_flags() {
        let mut bus = Bus::new();
        let pc = 0x4ff0_1000;
        // fdiv.s f3, f1, f2, dynamic
        bus.write_u32(
            pc,
            (0x0c << 25) | (2 << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x53,
        );
        for (left, right, mode, expected, flags) in [
            (0x3f80_0000, 0x4000_0000, 0, 0x3f00_0000, 0),
            (0x3f80_0000, 0x4040_0000, 0, 0x3eaa_aaab, 1),
            (0x3f80_0000, 0x4040_0000, 1, 0x3eaa_aaaa, 1),
            (0x3f80_0000, 0x4040_0000, 2, 0x3eaa_aaaa, 1),
            (0x3f80_0000, 0x4040_0000, 3, 0x3eaa_aaab, 1),
            (0x3f80_0000, 0x4040_0000, 4, 0x3eaa_aaab, 1),
            (0xbf80_0000, 0x4040_0000, 2, 0xbeaa_aaab, 1),
            (0xbf80_0000, 0x4040_0000, 3, 0xbeaa_aaaa, 1),
            (0x8000_0000, 0x4000_0000, 0, 0x8000_0000, 0),
            (0x3f80_0000, 0x0000_0000, 0, 0x7f80_0000, 8),
            (0x0000_0000, 0x0000_0000, 0, 0x7fc0_0000, 16),
            (0x7fc0_1234, 0x3f80_0000, 0, 0x7fc0_0000, 0),
            (0x7f80_1234, 0x3f80_0000, 0, 0x7fc0_0000, 16),
            (0x7f7f_ffff, 0x3f00_0000, 0, 0x7f80_0000, 5),
            (0x0000_0001, 0x4000_0000, 0, 0x0000_0000, 3),
            (0x0000_0001, 0x4000_0000, 3, 0x0000_0001, 3),
            (0x0000_0001, 0x4000_0000, 4, 0x0000_0001, 3),
            (0x0080_0000, 0x4000_0000, 0, 0x0040_0000, 0),
        ] {
            let mut cpu = Cpu::new(pc);
            cpu.f[1] = f32::from_bits(left);
            cpu.f[2] = f32::from_bits(right);
            cpu.fcsr = (mode << 5) | 0x08;
            assert!(cpu.step(&mut bus));
            assert_eq!(
                cpu.f[3].to_bits(),
                expected,
                "{left:x}/{right:x} mode={mode}"
            );
            assert_eq!(cpu.fcsr, (mode << 5) | 0x08 | flags);
        }
        let mut invalid = Cpu::new(pc);
        invalid.f[3] = 7.0;
        invalid.fcsr = 6 << 5;
        assert!(!invalid.step(&mut bus));
        assert_eq!(invalid.f[3], 7.0);
        assert_eq!(invalid.fcsr, 6 << 5);
    }

    #[test]
    fn flw_preserves_bits_and_does_not_publish_faulted_load() {
        let mut bus = Bus::new();
        let pc = 0x4ff0_1000;
        bus.write_u32(pc, (0xffc << 20) | (1 << 15) | (2 << 12) | (3 << 7) | 0x07);
        bus.write_u32(pc + 16, 0x7f80_1234);
        let mut cpu = Cpu::new(pc);
        cpu.x[1] = pc + 20;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.f[3].to_bits(), 0x7f80_1234);
        bus.write_u32(0x5008_e380, 3);
        bus.write_u32(0x5008_e37c, 0);
        cpu.pc = pc;
        cpu.x[1] = bus::FB_BASE + 4;
        assert!(!cpu.step(&mut bus));
        assert_eq!(cpu.f[3].to_bits(), 0x7f80_1234);
        assert!(cpu.fault.as_deref().unwrap().contains("PSRAM"));
    }

    #[test]
    fn fmul_s_handles_rounding_and_special_values() {
        let mut bus = Bus::new();
        let pc = 0x4ff0_1000;
        bus.write_u32(
            pc,
            (0x08 << 25) | (2 << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x53,
        );
        for (left, right, mode, expected, flags) in [
            (0x3fc0_0000, 0x4000_0000, 0, 0x4040_0000, 0),
            (0x0000_0000, 0x7f80_0000, 0, 0x7fc0_0000, 16),
            (0x7f80_1234, 0x3f80_0000, 0, 0x7fc0_0000, 16),
            (0x7f7f_ffff, 0x4000_0000, 0, 0x7f80_0000, 5),
            (0x0000_0001, 0x3f00_0000, 0, 0x0000_0000, 3),
            (0x0000_0001, 0x3f00_0000, 3, 0x0000_0001, 3),
            (0x0000_0001, 0x3f00_0000, 4, 0x0000_0001, 3),
        ] {
            let mut cpu = Cpu::new(pc);
            cpu.f[1] = f32::from_bits(left);
            cpu.f[2] = f32::from_bits(right);
            cpu.fcsr = mode << 5;
            assert!(cpu.step(&mut bus));
            assert_eq!(cpu.f[3].to_bits(), expected);
            assert_eq!(cpu.fcsr, (mode << 5) | flags);
        }
    }

    #[test]
    fn rom_reset_reason_and_memset_are_bounded() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0018);
        cpu.x[1] = 0x4ff0_0100;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 1);
        assert_eq!(cpu.pc, 0x4ff0_0100);
        cpu.pc = 0x4fc0_0268;
        cpu.x[10] = 0x4ff0_0001;
        cpu.x[11] = 0x1234;
        cpu.x[12] = 3;
        assert!(cpu.step(&mut bus));
        assert_eq!(&bus.sram[..5], &[0, 0x34, 0x34, 0x34, 0]);
        assert_eq!(cpu.x[10], 0x4ff0_0001);
        cpu.pc = 0x4fc0_0268;
        cpu.x[10] = 0x4fff_ffff;
        cpu.x[12] = 2;
        assert!(!cpu.step(&mut bus));
        assert!(cpu.fault.as_ref().unwrap().contains("outside RAM"));
    }

    #[test]
    fn rom_clock_frequency_and_delay_do_not_conflate_time_and_frequency() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0044);
        cpu.instructions_executed = 1;
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = 360;
        bus.timer_ticks = 123;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.timer_ticks, 123);
        cpu.pc = 0x4fc0_0040;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 360);
        cpu.pc = 0x4fc0_003c;
        cpu.x[10] = 10;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.timer_ticks, 3723);
        cpu.pc = 0x4fc0_003c;
        cpu.x[10] = 1_000_001;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.timer_ticks, 3723);
    }

    #[test]
    fn rom_console_wait_only_accepts_modeled_serial_port() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0078);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = 6;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.pc, 0x4ff0_0100);
        cpu.pc = 0x4fc0_0078;
        cpu.x[10] = 0;
        assert!(!cpu.step(&mut bus));
        assert!(cpu.fault.as_ref().unwrap().contains("console port"));
    }

    #[test]
    fn rom_interrupt_mask_changes_only_selected_lines_on_current_hart() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_05c0);
        cpu.mhartid = 1;
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = (1 << 2) | (1 << 25);
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u8(0x2080_1049), 1);
        assert_eq!(bus.read_u8(0x2080_10a5), 1);
        cpu.pc = 0x4fc0_05c4;
        cpu.x[10] = 1 << 25;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u8(0x2080_1049), 1);
        assert_eq!(bus.read_u8(0x2080_10a5), 0);
        bus.active_hart = 0;
        assert_eq!(bus.read_u8(0x2080_1049), 0);
    }

    #[test]
    fn rom_interrupt_route_validates_hart_source_and_line() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_05d0);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = 1;
        cpu.x[11] = 83;
        cpu.x[12] = 25;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x500d_6800 + 83 * 4), 41);
        assert_eq!(bus.read_u32(0x500d_6000 + 83 * 4), 0);
        cpu.pc = 0x4fc0_05d0;
        cpu.x[12] = 32;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x500d_6800 + 83 * 4), 41);
    }

    #[test]
    fn rom_interrupt_priority_updates_only_current_hart_control_byte() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_05b8);
        cpu.mhartid = 1;
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = 25;
        cpu.x[11] = 4;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u8(0x2080_10a7), 0x80);
        cpu.pc = 0x4fc0_05b8;
        cpu.x[11] = 8;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.read_u8(0x2080_10a7), 0x80);
        bus.active_hart = 0;
        assert_eq!(bus.read_u8(0x2080_10a7), 0);
    }

    #[test]
    fn rtc_calibration_requires_supported_clock_and_tracks_completion() {
        let mut bus = Bus::new();
        bus.write_u32(0x500e_6098, 8);
        bus.write_u32(0x500c_2068, 100 << 16);
        assert_eq!(bus.read_u32(0x500c_2068) & (1 << 15), 0);
        bus.write_u32(0x500c_2068, (100 << 16) | (1 << 31));
        assert_ne!(bus.read_u32(0x500c_2068) & (1 << 15), 0);
        assert_eq!(
            bus.read_u32(0x500c_206c) >> 7,
            (100u64 * 40_000_000 / 136_000) as u32
        );
        bus.write_u32(0x500c_2068, 100 << 16);
        assert_eq!(bus.read_u32(0x500c_2068) & (1 << 15), 0);
        bus.write_u32(0x500e_6098, 9);
        bus.write_u32(0x500c_2068, (100 << 16) | (1 << 31));
        assert!(
            bus.fault
                .as_ref()
                .unwrap()
                .contains("unsupported RTC calibration")
        );
        assert_eq!(bus.read_u32(0x500c_2068) & (1 << 15), 0);
    }

    #[test]
    fn clock_divider_update_self_clears_without_losing_other_fields() {
        let mut bus = Bus::new();
        bus.write_u32(0x500e_6004, 0x1234_5678);
        assert_eq!(bus.read_u32(0x500e_6004), 0x1234_5668);
    }

    #[test]
    fn analog_pll_banks_are_independent_and_cpll_requires_configuration() {
        let mut bus = Bus::new();
        let write = |bus: &mut Bus, block: u32, register: u32, value: u32| {
            bus.write_u32(
                0x5012_4000,
                (1 << 24) | (value << 16) | (register << 8) | block,
            );
        };
        write(&mut bus, 0x63, 2, 0x99);
        write(&mut bus, 0x67, 2, 0x11);
        bus.write_u32(0x5012_4000, (2 << 8) | 0x63);
        assert_eq!(bus.read_u32(0x5012_4000) >> 16, 0x99);
        assert_eq!(bus.read_u32(0x500e_60bc) & 4, 0);
        write(&mut bus, 0x67, 3, 0x22);
        assert_eq!(bus.read_u32(0x500e_60bc) & 4, 0);
        write(&mut bus, 0x67, 6, 0x73);
        assert_ne!(bus.read_u32(0x500e_60bc) & 4, 0);
        bus.write_u32(0x500e_60bc, 8);
        assert_eq!(bus.read_u32(0x500e_60bc) & 4, 0);
        bus.write_u32(0x500e_60bc, 0);
        write(&mut bus, 0x67, 6, 0x73);
        assert_eq!(bus.read_u32(0x500e_60bc) & 4, 0);
    }

    #[test]
    fn rom_l2_cache_profile_requires_supported_mode() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0404);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = 32;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.cache_l2_invalidations, 0);
        cpu.fault = None;
        cpu.pc = 0x4fc0_03d4;
        cpu.x[10] = 9;
        cpu.x[11] = 8;
        cpu.x[12] = 3;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.cache_l2_mode, Some((9, 8, 3)));
        cpu.pc = 0x4fc0_0404;
        cpu.x[10] = 32;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.cache_l2_invalidations, 1);
        assert_eq!(cpu.x[10], 0);
        cpu.pc = 0x4fc0_03d4;
        cpu.x[10] = 10;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.cache_l2_mode, Some((9, 8, 3)));
    }

    #[test]
    fn spi1_jedec_and_status_read_complete_but_writes_fail_closed() {
        let mut bus = Bus::new();
        bus.write_u32(0x5008_d018, 0x9000_0000);
        bus.write_u32(0x5008_d020, 0x7000_009f);
        bus.write_u32(0x5008_d028, 23);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert_eq!(bus.read_u32(0x5008_d000), 0);
        assert_eq!(bus.read_u32(0x5008_d058), 0x0018_40ef);
        assert!(bus.fault.is_none());
        bus.write_u32(0x5008_d020, 0x7000_0035);
        bus.write_u32(0x5008_d028, 7);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert_eq!(bus.read_u32(0x5008_d000), 0);
        assert_eq!(bus.read_u32(0x5008_d058), 0);
        bus.write_u32(0x5008_d020, 0x7000_0005);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert_eq!(bus.read_u32(0x5008_d058), 0);
        bus.write_u32(0x5008_d020, 0x7000_0006);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert!(bus.fault.as_ref().unwrap().contains("unsupported SPI1"));
        bus.fault = None;
        bus.write_u32(0x5008_d000, 1 << 30);
        assert_eq!(bus.read_u32(0x5008_d000), 0);
        bus.write_u32(0x5008_d020, 0x7000_0005);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert_eq!(bus.read_u32(0x5008_d058), 2);
        bus.write_u32(0x5008_d000, 1 << 29);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert_eq!(bus.read_u32(0x5008_d058), 0);
    }

    #[test]
    fn spi1_qe_write_requires_wel_and_reads_back_atomically() {
        let mut bus = Bus::new();
        bus.write_u32(0x5008_d018, 0x8800_0000);
        bus.write_u32(0x5008_d020, 0x7000_0001);
        bus.write_u32(0x5008_d024, 15);
        bus.write_u32(0x5008_d058, 0x200);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert!(bus.fault.take().unwrap().contains("unsupported SPI1"));
        bus.write_u32(0x5008_d000, 1 << 30);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert!(bus.fault.is_none());
        assert_eq!(bus.read_u32(0x5008_d000), 0);
        bus.write_u32(0x5008_d018, 0x9000_0000);
        bus.write_u32(0x5008_d028, 7);
        bus.write_u32(0x5008_d020, 0x7000_0035);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert_eq!(bus.read_u32(0x5008_d058), 2);
        bus.write_u32(0x5008_d020, 0x7000_0005);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert_eq!(bus.read_u32(0x5008_d058), 0);
        bus.write_u32(0x5008_d000, 1 << 30);
        bus.write_u32(0x5008_d018, 0x8800_0000);
        bus.write_u32(0x5008_d020, 0x7000_0001);
        bus.write_u32(0x5008_d058, 0x201);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert!(bus.fault.take().unwrap().contains("unsupported SPI1"));
        bus.write_u32(0x5008_d018, 0x9000_0000);
        bus.write_u32(0x5008_d020, 0x7000_0035);
        bus.write_u32(0x5008_d000, 1 << 18);
        assert_eq!(bus.read_u32(0x5008_d058), 2);
    }

    #[test]
    fn rom_spi_mode_rejects_unimplemented_controllers() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0110);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = 3;
        cpu.x[11] = 7;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.rom_spi_mode, Some((3, 7)));
        cpu.pc = 0x4fc0_0110;
        cpu.x[10] = 2;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.rom_spi_mode, None);
    }

    #[test]
    fn rom_memcpy_rejects_overlap_and_mmio_before_writing() {
        let mut bus = Bus::new();
        bus.flash[..4].copy_from_slice(&[1, 2, 3, 4]);
        let mut cpu = Cpu::new(0x4fc0_026c);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = 0x4ff0_0000;
        cpu.x[11] = 0x4000_0000;
        cpu.x[12] = 4;
        assert!(cpu.step(&mut bus));
        assert_eq!(&bus.sram[..4], &[1, 2, 3, 4]);
        assert_eq!(cpu.x[10], 0x4ff0_0000);
        cpu.pc = 0x4fc0_026c;
        cpu.x[11] = 0x4ff0_0001;
        assert!(!cpu.step(&mut bus));
        assert_eq!(&bus.sram[..4], &[1, 2, 3, 4]);
        cpu.fault = None;
        cpu.x[11] = 0x5000_0000;
        assert!(!cpu.step(&mut bus));
        assert_eq!(&bus.sram[..4], &[1, 2, 3, 4]);
    }

    #[test]
    fn rom_memcmp_compares_unsigned_bytes_and_rejects_mmio() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0274);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = 0x4ff0_0000;
        cpu.x[11] = 0x4ff0_0010;
        cpu.x[12] = 2;
        bus.sram[0..2].copy_from_slice(&[0xff, 1]);
        bus.sram[16..18].copy_from_slice(&[0x7f, 2]);
        assert!(cpu.step(&mut bus));
        assert!(cpu.x[10] as i32 > 0);
        cpu.pc = 0x4fc0_0274;
        cpu.x[10] = 0x5000_0000;
        assert!(!cpu.step(&mut bus));
        assert!(cpu.fault.as_ref().unwrap().contains("memcmp unsupported"));
    }

    #[test]
    fn rom_udivdi3_uses_rv32_register_pairs_and_rejects_zero() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0844);
        cpu.x[1] = 0x4ff0_0100;
        let dividend = 0xfedc_ba98_7654_3210u64;
        let divisor = 0x1_0000_0001u64;
        cpu.x[10] = dividend as u32;
        cpu.x[11] = (dividend >> 32) as u32;
        cpu.x[12] = divisor as u32;
        cpu.x[13] = (divisor >> 32) as u32;
        assert!(cpu.step(&mut bus));
        assert_eq!(
            u64::from(cpu.x[10]) | (u64::from(cpu.x[11]) << 32),
            dividend / divisor
        );
        cpu.pc = 0x4fc0_0844;
        cpu.x[12] = 0;
        cpu.x[13] = 0;
        assert!(!cpu.step(&mut bus));
        assert!(cpu.fault.as_ref().unwrap().contains("division by zero"));
    }

    #[test]
    fn rom_clzsi2_handles_zero_and_high_bits() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0770);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = 0;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 32);
        cpu.pc = 0x4fc0_0770;
        cpu.x[10] = 0x0100_0000;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 7);
    }

    #[test]
    fn systimer_tick_callbacks_are_copied_and_invalid_pointers_rejected() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0230);
        let ctx = 0x4ff0_0100;
        let ops = 0x4ff0_0200;
        bus.write_u32(ctx, 0x5010_0000);
        bus.write_u32(ops, 0x4000_0100);
        bus.write_u32(ops + 4, 0x4ff0_0300);
        cpu.x[1] = 0x4ff0_0400;
        cpu.x[10] = ctx;
        cpu.x[11] = ops;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(ctx), 0x5010_0000);
        assert_eq!(bus.read_u32(ctx + 4), 0x4000_0100);
        assert_eq!(bus.read_u32(ctx + 8), 0x4ff0_0300);
        cpu.pc = 0x4fc0_0230;
        bus.write_u32(ops + 4, 0x5000_0000);
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.read_u32(ctx + 4), 0x4000_0100);
        assert_eq!(bus.read_u32(ctx + 8), 0x4ff0_0300);
    }

    #[test]
    fn systimer_rom_counter_returns_rv32_register_pair() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0234);
        let ctx = 0x4ff0_0100;
        bus.write_u32(ctx, 0x500e_2000);
        bus.write_u32(0x500e_2000, 1 << 30);
        bus.timer_ticks = 360 * (1u64 << 28);
        cpu.instructions_executed = 1;
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = ctx;
        cpu.x[11] = 0;
        assert!(cpu.step(&mut bus));
        assert_eq!((cpu.x[11], cpu.x[10]), (1, 0));
        assert_eq!(cpu.pc, 0x4ff0_0200);
    }

    #[test]
    fn systimer_alarm_routes_to_vectored_clic_and_rearms() {
        let mut bus = Bus::new();
        let base = 0x500e_2000;
        bus.write_u32(base + 0x20, 160);
        bus.write_u32(base + 0x50, 1);
        bus.write_u32(base + 0x64, 1);
        bus.write_u32(0x500d_6000 + 53 * 4, 36);
        bus.write_u8(0x2080_1000 + 36 * 4 + 1, 1);
        bus.write_u8(0x2080_1000 + 36 * 4 + 2, 1);
        bus.write_u32(base, (1 << 30) | (1 << 24));
        bus.timer_ticks = 9 * 360;
        assert_eq!(bus.pending_irq(0), None);
        bus.timer_ticks = 10 * 360;
        assert_eq!(bus.pending_irq(0), Some(36));
        assert_eq!(bus.read_u32(base + 0x70), 1);
        let mut cpu = Cpu::new(0x4ff0_0100);
        cpu.mstatus |= 8;
        cpu.mtvt = 0x4ff0_0200;
        bus.write_u32(cpu.mtvt + 36 * 4, 0x4ff0_0400);
        bus.write_u32(0x4ff0_0400, 0x0070_0513); // addi a0, zero, 7
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.mepc, 0x4ff0_0100);
        assert_eq!(cpu.mcause, 0x8000_0024);
        assert_eq!(cpu.x[10], 7);
        bus.write_u32(base + 0x6c, 1);
        assert_eq!(bus.pending_irq(0), None);
        bus.write_u32(base + 0x20, 320);
        bus.write_u32(base + 0x50, 1);
        bus.timer_ticks = 20 * 360;
        assert_eq!(bus.pending_irq(0), Some(36));
        bus.write_u32(base + 0x64, 0);
        assert_eq!(bus.pending_irq(0), None);
        assert_eq!(bus.read_u32(base + 0x68), 1);
    }

    #[test]
    fn psram_mmu_indexed_readback_is_per_entry() {
        let mut bus = Bus::new();
        bus.write_u32(0x5008_e380, 3);
        bus.write_u32(0x5008_e37c, 0xc07);
        bus.write_u32(0x5008_e380, 4);
        bus.write_u32(0x5008_e37c, 0xc00);
        assert_eq!(bus.read_u32(0x5008_e37c), 0xc00);
        assert_eq!(bus.translate_psram(0x4804_0010), Some(0x10));
        bus.write_u32(0x5008_e380, 3);
        assert_eq!(bus.read_u32(0x5008_e37c), 0xc07);
        assert_eq!(bus.translate_psram(0x4803_0010), Some(0x70010));
        bus.write_u32(0x5008_e380, 5);
        assert_eq!(bus.read_u32(0x5008_e37c), 0);
    }

    #[test]
    fn psram_mmu_rejects_invalid_and_out_of_capacity_pages() {
        let mut bus = Bus::new();
        bus.psram[0] = 0xa5;
        bus.write_u32(0x5008_e380, 4);
        for value in [0, 0x400, 0x800, 0xc00 | 512, 0x1c00] {
            bus.write_u32(0x5008_e37c, value);
            assert_eq!(bus.read_u32(0x5008_e37c), value);
            assert_eq!(bus.translate_psram(0x4804_0000), None);
            bus.write_u8(0x4804_0000, 0x42);
            assert!(bus.fault.take().unwrap().contains("unmapped PSRAM write"));
            assert_eq!(bus.read_u8(0x4804_0000), 0);
            assert!(bus.fault.take().unwrap().contains("unmapped PSRAM read"));
            assert_eq!(bus.psram[0], 0xa5);
        }
        bus.write_u32(0x5008_e37c, 0xc00 | 511);
        assert_eq!(bus.translate_psram(0x4804_0000), Some(511 * 65536));
        bus.write_u8(0x4804_0000, 0x33);
        assert_eq!(bus.psram[511 * 65536], 0x33);
    }

    #[test]
    fn rom_memory_calls_reject_unmapped_page_before_mutating() {
        let mut bus = Bus::new();
        bus.write_u32(0x5008_e380, 1);
        bus.write_u32(0x5008_e37c, 0);
        let edge = 0x4800_fffe;
        bus.write_u8(edge, 0xaa);
        bus.write_u8(edge + 1, 0xbb);
        bus.write_u32(0x4ff0_0100, 0x1122_3344);
        for (pc, a0, a1, a2) in [
            (0x4fc0_0268, edge, 0x55, 4),
            (0x4fc0_0290, edge, 4, 0),
            (0x4fc0_026c, edge, 0x4ff0_0100, 4),
            (0x4fc0_0270, edge, 0x4ff0_0100, 4),
            (0x4fc0_027c, edge, 0x4ff0_0100, 4),
            (0x4fc0_026c, 0x4ff0_0100, edge, 4),
            (0x4fc0_0270, 0x4ff0_0100, edge, 4),
        ] {
            let mut cpu = Cpu::new(pc);
            cpu.x[1] = 0x4ff0_0200;
            cpu.x[10] = a0;
            cpu.x[11] = a1;
            cpu.x[12] = a2;
            assert!(
                !cpu.step(&mut bus),
                "operation {pc:#x} must reject unmapped page"
            );
            assert_eq!(bus.read_u8(edge), 0xaa);
            assert_eq!(bus.read_u8(edge + 1), 0xbb);
            assert_eq!(bus.read_u32(0x4ff0_0100), 0x1122_3344);
            assert!(bus.fault.is_none());
        }
    }

    #[test]
    fn rom_printf_does_not_emit_partial_text_for_unmapped_psram_string() {
        let mut bus = Bus::new();
        bus.write_u32(0x5008_e380, 1);
        bus.write_u32(0x5008_e37c, 0);
        for (i, byte) in b"prefix:%s\0".iter().enumerate() {
            bus.write_u8(0x4ff0_0100 + i as u32, *byte);
        }
        bus.write_u8(0x4800_ffff, b'x');
        bus.console_output.extend_from_slice(b"existing");
        let mut cpu = Cpu::new(0x4fc0_0024);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_0100;
        cpu.x[11] = 0x4800_ffff;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.console_output, b"existing");
        assert!(bus.fault.is_none());
    }

    #[test]
    fn fast_memory_reads_match_byte_reads_at_unaligned_and_region_edges() {
        let mut bus = Bus::new();
        for base in [0x4000_0000, 0x4ff0_0000] {
            for i in 0..8 {
                bus.write_u8(base + i, (0x80 + i) as u8);
            }
            assert_eq!(bus.read_u16(base + 1), 0x8281);
            assert_eq!(bus.read_u32(base + 1), 0x8483_8281);
        }
        bus.write_u8(0x40ff_ffff, 0x5a);
        assert_eq!(bus.read_u16(0x40ff_ffff), 0x005a);
        bus.write_u8(0x4fff_ffff, 0xa5);
        assert_eq!(bus.read_u32(0x4fff_ffff) & 0xff, 0xa5);
        bus.cache_l2_suspended = true;
        assert_eq!(bus.read_u32(0x4000_0000), 0);
        assert!(bus.fault.take().unwrap().contains("L2 suspended"));
    }

    #[test]
    fn rom_newlib_mutex_init_copies_values_and_rejects_invalid_pointers() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0264);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_0100;
        cpu.x[11] = 0x4ff0_0104;
        bus.write_u32(cpu.x[10], 0x1234_5678);
        bus.write_u32(cpu.x[11], 0xbb10_c433);
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff3_ff8c), 0x1234_5678);
        assert_eq!(bus.read_u32(0x4ff3_ff88), 0xbb10_c433);
        assert_eq!(cpu.pc, 0x4ff0_0200);
        cpu.pc = 0x4fc0_0264;
        cpu.x[11] = 0x4ff3_ff8c;
        bus.write_u32(cpu.x[10], 0xdead_beef);
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff3_ff88), 0xdead_beef);
        cpu.pc = 0x4fc0_0264;
        cpu.x[11] = 0x5000_0000;
        bus.write_u32(cpu.x[10], 0);
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff3_ff8c), 0xdead_beef);
        assert_eq!(bus.read_u32(0x4ff3_ff88), 0xdead_beef);
    }

    #[test]
    fn rom_strlen_counts_bytes_and_rejects_unmapped_strings() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0288);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_0100;
        for (i, byte) in [0xc3, 0xa9, 0].into_iter().enumerate() {
            bus.write_u8(0x4ff0_0100 + i as u32, byte);
        }
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 2);
        cpu.pc = 0x4fc0_0288;
        cpu.x[10] = 0x4fff_ffff;
        bus.write_u8(cpu.x[10], b'x');
        assert!(!cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 0x4fff_ffff);
    }

    #[test]
    fn rom_strcpy_includes_terminator_and_rejects_overlap_without_writes() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0278);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_0110;
        cpu.x[11] = 0x4ff0_0100;
        for (i, byte) in b"abc\0".iter().enumerate() {
            bus.write_u8(cpu.x[11] + i as u32, *byte);
        }
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff0_0110), 0x0063_6261);
        assert_eq!(cpu.x[10], 0x4ff0_0110);
        cpu.pc = 0x4fc0_0278;
        cpu.x[10] = 0x4ff0_0101;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff0_0100), 0x0063_6261);
    }

    #[test]
    fn rom_strncpy_pads_and_does_not_append_when_truncated() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_027c);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_0110;
        cpu.x[11] = 0x4ff0_0100;
        cpu.x[12] = 4;
        bus.write_u32(0x4ff0_0100, 0x0000_6261);
        bus.write_u32(0x4ff0_0110, u32::MAX);
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff0_0110), 0x0000_6261);
        bus.write_u32(0x4ff0_0100, 0x6463_6261);
        cpu.pc = 0x4fc0_027c;
        cpu.x[12] = 3;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff0_0110), 0x0063_6261);
        cpu.pc = 0x4fc0_027c;
        cpu.x[11] = 0x5000_0000;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff0_0110), 0x0063_6261);
    }

    #[test]
    fn rom_bzero_writes_only_the_requested_ram_range() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0290);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_0101;
        cpu.x[11] = 2;
        bus.write_u32(0x4ff0_0100, u32::MAX);
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff0_0100), 0xff00_00ff);
        cpu.pc = 0x4fc0_0290;
        cpu.x[10] = 0x4fff_ffff;
        assert!(!cpu.step(&mut bus));
    }

    #[test]
    fn rom_strncmp_stops_at_nul_or_limit_and_compares_unsigned_bytes() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0284);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_0100;
        cpu.x[11] = 0x4ff0_0110;
        cpu.x[12] = 2;
        bus.write_u8(cpu.x[10], 0xff);
        bus.write_u8(cpu.x[11], 0x01);
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 254);
        cpu.pc = 0x4fc0_0284;
        cpu.x[10] = 0x5000_0000;
        cpu.x[12] = 0;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 0);
        cpu.pc = 0x4fc0_0284;
        cpu.x[10] = 0x5000_0000;
        cpu.x[12] = 1;
        assert!(!cpu.step(&mut bus));
    }

    #[test]
    fn rom_strcmp_stops_at_nul_and_orders_unsigned_bytes() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0280);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_0100;
        cpu.x[11] = 0x4ff0_0110;
        bus.write_u32(cpu.x[10], 0x0000_ff61);
        bus.write_u32(cpu.x[11], 0x0000_0161);
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 254);
        cpu.pc = 0x4fc0_0280;
        cpu.x[10] = 0x4fff_ffff;
        cpu.x[11] = 0x4fff_ffff;
        bus.write_u8(0x4fff_ffff, 1);
        assert!(!cpu.step(&mut bus));
    }

    #[test]
    fn rom_flash_guard_set_get_share_guest_visible_storage() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_01f0);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_1234;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff3_fff0), 0x4ff0_1234);
        bus.write_u32(0x4ff3_fff0, 0x4ff0_5678);
        cpu.pc = 0x4fc0_01f4;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 0x4ff0_5678);
    }

    #[test]
    fn rom_memchr_respects_length_and_rejects_unmapped_input() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_02dc);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_0100;
        cpu.x[11] = 0x1ff;
        cpu.x[12] = 2;
        bus.write_u8(0x4ff0_0101, 0xff);
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 0x4ff0_0101);
        cpu.pc = 0x4fc0_02dc;
        cpu.x[10] = 0x5000_0000;
        cpu.x[12] = 0;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 0);
        cpu.pc = 0x4fc0_02dc;
        cpu.x[10] = 0x5000_0000;
        cpu.x[12] = 1;
        assert!(!cpu.step(&mut bus));
    }

    #[test]
    fn rom_memmove_handles_overlap_and_rejects_invalid_destination() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0270);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x4ff0_0101;
        cpu.x[11] = 0x4ff0_0100;
        cpu.x[12] = 3;
        bus.write_u32(cpu.x[11], 0x6463_6261);
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff0_0100), 0x6362_6161);
        cpu.pc = 0x4fc0_0270;
        cpu.x[10] = 0x5000_0000;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x4ff0_0100), 0x6362_6161);
    }

    #[test]
    fn rom_umoddi3_uses_register_pairs_and_rejects_zero() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0854);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 5;
        cpu.x[11] = 2;
        cpu.x[12] = 3;
        assert!(cpu.step(&mut bus));
        assert_eq!((cpu.x[11], cpu.x[10]), (0, 1));
        cpu.pc = 0x4fc0_0854;
        cpu.x[12] = 0;
        assert!(!cpu.step(&mut bus));
    }

    #[test]
    fn rom_div_returns_signed_quotient_and_remainder() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_033c);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = (-7i32) as u32;
        cpu.x[11] = 3;
        assert!(cpu.step(&mut bus));
        assert_eq!((cpu.x[10] as i32, cpu.x[11] as i32), (-2, -1));
        cpu.pc = 0x4fc0_033c;
        cpu.x[10] = i32::MIN as u32;
        cpu.x[11] = (-1i32) as u32;
        assert!(!cpu.step(&mut bus));
    }

    #[test]
    fn rom_cache_writeback_only_accepts_l1_data_map() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0414);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 16;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 0);
        cpu.pc = 0x4fc0_0414;
        cpu.x[10] = 32;
        assert!(!cpu.step(&mut bus));
    }

    #[test]
    fn rom_gpio_pad_selection_preserves_other_mux_bits() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0590);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 32;
        let address = 0x500e_1004 + 32 * 4;
        bus.write_u32(address, 0xabcd_7523);
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(address), 0xabcd_1523);
        cpu.pc = 0x4fc0_0590;
        cpu.x[10] = 57;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(address), 0xabcd_1523);
    }

    #[test]
    fn rom_gpio_matrix_selects_input_and_rejects_invalid_arguments() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_056c);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 0x3e;
        cpu.x[11] = 42;
        cpu.x[12] = 1;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.pc, 0x4ff0_0200);
        assert_eq!(bus.read_u32(0x500e_0158 + 42 * 4), 0xfe);
        cpu.pc = 0x4fc0_056c;
        cpu.x[10] = 57;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x500e_0158 + 42 * 4), 0xfe);
    }

    #[test]
    fn rom_gpio_matrix_selects_signal_and_enables_output() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0570);
        cpu.x[1] = 0x4ff0_0200;
        cpu.x[10] = 32;
        cpu.x[11] = 256;
        cpu.x[12] = 1;
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x500e_0558 + 32 * 4), 0x300);
        assert_eq!(bus.read_u32(0x500e_002c) & 1, 1);
        cpu.pc = 0x4fc0_0570;
        cpu.x[10] = 57;
        assert!(!cpu.step(&mut bus));
        assert_eq!(bus.read_u32(0x500e_002c) & 1, 1);
    }

    #[test]
    fn l2_suspend_resume_tracks_autoload_and_blocks_cached_access() {
        let mut bus = Bus::new();
        bus.cache_l2_mode = Some((9, 8, 3));
        bus.cache_l2_autoload = true;
        bus.write_u8(0x4800_0000, 0x42);
        let mut cpu = Cpu::new(0x4fc0_0508);
        cpu.x[1] = 0x4ff0_0200;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 1);
        assert_ne!(bus.read_u32(0x5008_c03c) & (1 << 31), 0);
        bus.write_u8(0x4800_0000, 0x99);
        assert!(
            bus.fault
                .take()
                .unwrap()
                .contains("write while L2 suspended")
        );
        let mut flash_cpu = Cpu::new(0x4000_0000);
        assert!(!flash_cpu.step(&mut bus));
        assert!(flash_cpu.fault.unwrap().contains("read while L2 suspended"));
        cpu.pc = 0x4fc0_050c;
        cpu.x[10] = 1;
        assert!(cpu.step(&mut bus));
        assert!(!bus.cache_l2_suspended);
        assert!(bus.cache_l2_autoload);
        assert_eq!(bus.read_u32(0x5008_c03c) & (1 << 31), 0);
        assert_eq!(bus.read_u8(0x4800_0000), 0x42);
        cpu.pc = 0x4fc0_050c;
        assert!(!cpu.step(&mut bus));
    }

    #[test]
    fn rom_instructions_require_opt_in_and_executable_segment() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0b00);
        bus.rom_data[0xb00..0xb08]
            .copy_from_slice(&[0x13, 0x05, 0x70, 0x00, 0x67, 0x80, 0x00, 0x00]);
        bus.rom_executable.push((0x4fc0_0b00, 0x4fc0_0b08));
        assert!(!cpu.step(&mut bus));
        let mut cpu = Cpu::new(0x4fc0_0b00);
        cpu.x[1] = 0x4ff0_0200;
        bus.rom_execute = true;
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.x[10], 7);
        assert!(cpu.step(&mut bus));
        assert_eq!(cpu.pc, 0x4ff0_0200);
        cpu.pc = 0x4fc0_0b08;
        assert!(!cpu.step(&mut bus));
    }

    #[test]
    fn rom_ffssi2_returns_one_based_bit_position() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_07a0);
        cpu.x[1] = 0x4ff0_0100;
        for (value, expected) in [(0, 0), (1, 1), (0x8000_0000, 32), (0x18, 4)] {
            cpu.pc = 0x4fc0_07a0;
            cpu.x[10] = value;
            assert!(cpu.step(&mut bus));
            assert_eq!(cpu.x[10], expected);
        }
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
        let b_home = b.bus.scanout().map(<[u8]>::to_vec).unwrap();
        let paused_steps = a.total_steps;
        let paused_pc = a.cpu.pc;
        let paused_frame = a.bus.scanout().map(<[u8]>::to_vec);
        a.paused = true;
        a.step_frame(1_000_000);
        assert_eq!(a.total_steps, paused_steps);
        assert_eq!(a.cpu.pc, paused_pc);
        assert_eq!(a.bus.scanout(), paused_frame.as_deref());
        a.paused = false;
        a.send_key(b'n');
        a.step_frame(90_000_000);
        a.send_key(b'A');
        a.step_frame(90_000_000);
        assert!(a.bus.keyboard_fifo.is_empty());
        assert_eq!(b.bus.scanout().unwrap(), &b_home);
        b.send_key(b'n');
        b.step_frame(90_000_000);
        b.send_key(b'B');
        b.step_frame(90_000_000);
        assert!(b.bus.keyboard_fifo.is_empty());
        // The enabled touch service and editor can repaint at different times.
        // Wait for both sessions to present distinct edits, with a bound.
        for _ in 0..4 {
            if a.bus.scanout() != b.bus.scanout() {
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
            a.bus.scanout() != b.bus.scanout(),
            "independent inputs did not produce distinct frames"
        );
        let b_document = b.bus.scanout().map(<[u8]>::to_vec);
        a.reset().unwrap();
        a.step_frame(5_000_000);
        assert_eq!(b.bus.scanout(), b_document.as_deref());
        assert!(a.bus.scanout().is_none());
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
                let home = emu.bus.scanout().map(<[u8]>::to_vec).expect("home frame");
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
                    *emu.bus.scanout().unwrap(),
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
                let home = emu.bus.scanout().map(<[u8]>::to_vec).expect("home frame");
                emu.bus.touch(Some((200, 220)));
                emu.bus.touch(None);
                emu.step_frame(90_000_000);
                let document = emu
                    .bus
                    .scanout()
                    .map(<[u8]>::to_vec)
                    .expect("document frame");
                assert!(home != document, "portrait tap did not open document");
                // q is in the first row of the portrait software keyboard.
                emu.bus.touch(Some((36, 1000)));
                emu.bus.touch(None);
                emu.step_frame(90_000_000);
                assert!(
                    document != *emu.bus.scanout().unwrap(),
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
                let home = emu.bus.scanout().map(<[u8]>::to_vec).expect("home frame");
                emu.send_key(b'n');
                emu.step_frame(30_000_000);
                assert!(
                    emu.bus.keyboard_fifo.is_empty(),
                    "guest did not consume navigation input"
                );
                let document = emu
                    .bus
                    .scanout()
                    .map(<[u8]>::to_vec)
                    .expect("document frame");
                assert_ne!(home, document, "navigation did not repaint the display");
                emu.send_key(b'X');
                emu.step_frame(30_000_000);
                assert!(
                    emu.bus.keyboard_fifo.is_empty(),
                    "guest did not consume editor input"
                );
                assert_ne!(
                    document,
                    *emu.bus.scanout().unwrap(),
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
            if let Some(line) = output
                .lines()
                .find(|line| line.contains("NIHOS_NATIVE_XY_IDLE "))
            {
                eprintln!("xy_backing {line}");
                assert!(line.contains("backing_reserved=00400000"), "{line}");
                return;
            }
        }
        panic!(
            "no backing allocation report: {}",
            String::from_utf8_lossy(&emu.bus.console_output)
        );
    }

    // Requires an xy trace ELF built from the exact candidate under test.
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF with xy trace enabled"]
    fn firmware_nested_gc_pressure_and_recovery() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let expected =
            std::env::var("NIHOS_EMU_GC_EXPECT").expect("set NIHOS_EMU_GC_EXPECT to done or full");
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
        let mut run = |source: &str, expected_reply: &str| {
            assert!(source.len() < 256);
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            emu.step_frame(30_000_000);
            if source == "(let ((result (work 3))) result)" {
                if let Ok(entry) = std::env::var("NIHOS_EMU_GC_ENTRY") {
                    emu.gc_probe = Some(GcInstructionProbe {
                        entry: u32::from_str_radix(entry.trim_start_matches("0x"), 16)
                            .expect("invalid GC entry"),
                        active: None,
                        samples: Vec::new(),
                    });
                }
            }
            for byte in source.bytes().chain(std::iter::once(b'\r')) {
                emu.send_key(byte);
            }
            let hex: String = expected_reply.bytes().map(|b| format!("{b:02x}")).collect();
            let expected_line = format!("NIHOS_NATIVE_XY_REPLY data={hex}");
            let mut checkpoint = start;
            let cancel = std::env::var_os("NIHOS_EMU_GC_CANCEL").is_some();
            let abort = std::env::var_os("NIHOS_EMU_GC_ABORT").is_some();
            let inject = source == "(let ((result (work 3))) result)"
                && (abort || cancel || std::env::var_os("NIHOS_EMU_GC_INJECT").is_some());
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
                let reply_seen = completed
                    .lines()
                    .any(|line| line.trim_end_matches('\r') == expected_line);
                let replay_marker = if cancel {
                    "NIHOS_NATIVE_XY_READER screen=00000001"
                } else {
                    "bytes=00000001"
                };
                let replayed = if abort {
                    reply_seen
                } else {
                    inject
                        && output.contains("NIHOS_XY_GC_RESULT done")
                        && output.contains(replay_marker)
                };
                if if inject { replayed } else { reply_seen } {
                    if inject {
                        if abort {
                            let seen = output
                                .find("NIHOS_XY_GC_CANCEL_SEEN")
                                .expect("cancel not observed during GC");
                            let safe = output
                                .find("NIHOS_XY_GC_CANCEL_SAFE")
                                .expect("collector did not complete after cancel");
                            let result = output
                                .find("NIHOS_XY_GC_RESULT Evaluation cancelled")
                                .expect("missing cancellation result");
                            assert!(
                                injected && seen < safe && safe < result,
                                "invalid cancellation ordering: {output}"
                            );
                        } else {
                            assert!(
                                injected && output.contains("NIHOS_XY_GC_DEFERRED"),
                                "input was not deferred during GC: {output}"
                            );
                            assert!(
                                output.contains(replay_marker),
                                "deferred input was not replayed: {output}"
                            );
                        }
                        if std::env::var_os("NIHOS_EMU_GC_REPAINT").is_some() {
                            assert!(
                                output.contains("NIHOS_XY_GC_REPAINT"),
                                "no repaint while collecting: {output}"
                            );
                        }
                        if std::env::var_os("NIHOS_EMU_GC_OVERLAP").is_some() {
                            assert!(
                                output.contains("NIHOS_XY_GC_OVERLAP_REJECTED"),
                                "overlap test missing: {output}"
                            );
                            eprintln!("gc_foreground overlapping_stack=rejected");
                        }
                        if std::env::var_os("NIHOS_EMU_GC_TRAPS").is_some() {
                            let line = output
                                .lines()
                                .find(|line| line.contains("NIHOS_XY_GC_STACK_CAPTURES"))
                                .expect("missing GC stack capture counters");
                            let counter = |name: &str| {
                                let value = line
                                    .split_whitespace()
                                    .find_map(|part| part.strip_prefix(name))
                                    .expect("missing stack counter");
                                u32::from_str_radix(value, 16).expect("invalid stack counter")
                            };
                            let eval = counter("eval=");
                            let render = counter("render=");
                            assert!(eval > 0 && render > 0, "timer capture missing: {line}");
                            eprintln!("gc_stack_captures eval={eval} render={render}");
                        }
                        eprintln!(
                            "gc_input pump=active repaint={} result={} replay={}",
                            output.contains("NIHOS_XY_GC_REPAINT"),
                            if abort { "cancelled" } else { "done" },
                            if abort {
                                "none"
                            } else if cancel {
                                "cancel-home"
                            } else {
                                "text"
                            }
                        );
                        if cancel {
                            let resume = emu.bus.console_output.len();
                            emu.send_key(b'n');
                            let mut returned = false;
                            for _ in 0..200 {
                                emu.step_frame(5_000_000);
                                let state =
                                    String::from_utf8_lossy(&emu.bus.console_output[resume..]);
                                if state.contains("NIHOS_NATIVE_XY_READER screen=00000000") {
                                    returned = true;
                                    break;
                                }
                            }
                            assert!(
                                returned,
                                "could not return to scratch after deferred cancel"
                            );
                        }
                    }
                    eprintln!(
                        "nested_gc source_len={} reply={expected_reply}",
                        source.len()
                    );
                    if let Some(probe) = emu.gc_probe.take() {
                        assert!(probe.active.is_none(), "GC probe ended inside collection");
                        assert!(!probe.samples.is_empty(), "GC entry not observed");
                        let count = probe.samples.len();
                        let total: u64 = probe.samples.iter().sum();
                        let min = probe.samples.iter().min().unwrap();
                        let max = probe.samples.iter().max().unwrap();
                        eprintln!(
                            "gc_cpu0_instructions count={count} total={total} min={min} max={max} first={:?}",
                            &probe.samples[..count.min(8)]
                        );
                    }
                    return;
                }
            }
            panic!(
                "missing expected reply for {source}: {}",
                String::from_utf8_lossy(&emu.bus.console_output[start..])
            );
        };
        let root = format!("(define root '({}))", vec!["0"; 116].join(" "));
        run(&root, "()");
        for _ in 0..5 {
            run("(set! root (append root root))", "()");
        }
        run(
            "(define (alloc n acc) (if (= n 0) acc (alloc (- n 1) (cons n acc))))",
            "()",
        );
        run(
            "(define (work n) (if (= n 0) 'done (begin (let ((a (alloc 70 '()))) (let ((b (alloc 70 '()))) (+ (length a) (length b)))) (work (- n 1)))))",
            "()",
        );
        let reply = match expected.as_str() {
            "done" => "done",
            "full" => "Scheme heap full",
            "cancelled" => "Evaluation cancelled",
            _ => panic!("invalid NIHOS_EMU_GC_EXPECT"),
        };
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
                "(map (lambda (x) (* x x)) '(1 2 3 4))",
                "28312034203920313629",
            ),
            ("(map + '(1 2 3) '(10 20 30))", "28313120323220333329"),
            (
                "(begin (define (many n a) (if (= n 0) a (many (- n 1) (cons 1 a)))) (if (equal? (many 129 '()) (many 129 '())) 709 708))",
                "373039",
            ),
            ("(if (equal? '(a (b c)) '(a (b c))) 710 711)", "373130"),
            ("(if (equal? '(a (b c)) '(a (b d))) 712 713)", "373133"),
            (
                "(memq 'red '(red shoes blue socks))",
                "287265642073686f657320626c756520736f636b7329",
            ),
            ("(cadr '((x1 x2) (y1 y2)))", "28793120793229"),
            ("(let* ((x 1) (f (lambda () x)) (x 2)) (f))", "31"),
            (
                "(let* ((n 6) (d -8) (g (gcd n d)) (a (/ n g)) (b (/ d g))) (cons (- a) (- b)))",
                "282d33202e203429",
            ),
            (
                "(map + '(1) '(2 3))",
                "57726f6e6720617267756d656e742074797065",
            ),
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
                    eprintln!("sicp_lists source={source} reply={expected_line}");
                    matched = true;
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
                "(begin (define (xp b n a) (cond ((= n 0) a) ((even? n) (xp (* b b) (quotient n 2) a)) (else (xp b (- n 1) (* a b))))) (xp 3 7 1))",
                "32313837",
            ),
            (
                "(let* ((a (cons -3 2)) (b (cons 5 -4))) (cons (/ (+ (car a) (car b)) 2) (/ (+ (cdr a) (cdr b)) 2)))",
                "2831202e202d3129",
            ),
            (
                "(let* ((a (let ((n 5)) (lambda (x) (set! n (+ n x)) n))) (x (a 10)) (y (a 10))) (list x y))",
                "28313520323529",
            ),
            (
                "(let ((x (list 1 2))) (set-car! x 7) (set-cdr! (cdr x) x) (list (car x) (list? x)))",
                "283720236629",
            ),
            (
                "(let ((q (cons '() '()))) (let ((n (list 'a))) (set-car! q n) (set-cdr! q n)) (let ((n (list 'b))) (set-cdr! (cdr q) n) (set-cdr! q n)) (car q))",
                "2861206229",
            ),
            (
                "(let ((e '(define x 3))) (list (pair? e) (eq? (car e) 'call)))",
                "28237420236629",
            ),
            (
                "(begin (define (fact n) (define (iter p c) (if (> c n) p (iter (* c p) (+ c 1)))) (iter 1 1)) (fact 5))",
                "313230",
            ),
            (
                "(begin (define (same-parity f . r) (define (k xs) (cond ((null? xs) '()) ((= (remainder (abs (car xs)) 2) (remainder (abs f) 2)) (cons (car xs) (k (cdr xs)))) (else (k (cdr xs))))) (cons f (k r))) (same-parity 1 2 3 4 5 6 7))",
                "283120332035203729",
            ),
            (
                "(list (symbol? 'x) (string? \"x\") (boolean? #f) (procedure? +))",
                "28237420237420237420237429",
            ),
            ("(list (caddr '(1 2 3)) (caadr '(a (b c))))", "2833206229"),
            (
                "(let ((seen '())) (for-each (lambda (x) (set! seen (cons x seen))) '(1 2 3)) seen)",
                "28332032203129",
            ),
            (
                "(assoc '(a b) '(((x) . 1) ((a b) . 2)))",
                "282861206229202e203229",
            ),
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
                    eprintln!("sicp_five source={source} reply={expected_line}");
                    matched = true;
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
        let placement = output
            .lines()
            .find(|line| line.contains("NIHOS_NATIVE_XY_PSRAM "))
            .expect("missing workspace placement");
        let field = |name: &str| -> u32 {
            u32::from_str_radix(
                placement
                    .split_whitespace()
                    .find_map(|s| s.strip_prefix(name))
                    .expect("missing field"),
                16,
            )
            .expect("invalid field")
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
                let first = (256..stack_bytes)
                    .find(|i| {
                        let offset = emu
                            .bus
                            .translate_psram(stack_low + i)
                            .expect("mapped evaluation stack");
                        emu.bus.psram[offset] != 0xa5
                    })
                    .unwrap_or(stack_bytes);
                let used = stack_bytes - first;
                assert!(
                    (0..256).all(|i| emu.bus.psram[emu
                        .bus
                        .translate_psram(stack_low + i)
                        .expect("mapped evaluation stack guard")]
                        == 0xa5),
                    "stack guard changed"
                );
                assert!(used > 0, "invalid stack watermark");
                eprintln!(
                    "sicp_stack_watermark source={source} low={stack_low:#x} bytes={stack_bytes} observed_used={used}"
                );
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
