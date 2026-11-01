//! Memory bus and MMIO mapping for ESP32-P4 emulation.
//!
//! Address Map:
//!   0x4000_0000..0x4100_0000 : Flash MMIO (16 MiB)
//!   0x4800_0000..0x4a00_0000 : PSRAM (32 MiB) [0x4800_0000 = Framebuffer 1280x720 RGB565]
//!   0x4fc0_0000..0x4fc1_0000 : Boot ROM (64 KiB)
//!   0x4ff0_0000..0x5000_0000 : SRAM (1 MiB) [0x4ff2_0000 = Text, 0x4ff6_0000 = Stack]
//!   0x5000_0000..0x6000_0000 : MMIO Peripherals (MSPI, Timer, UART, PMU, LCD, etc.)

use std::collections::HashMap;

pub const FLASH_BASE: u32 = 0x4000_0000;
pub const FLASH_SIZE: usize = 16 * 1024 * 1024;

pub const PSRAM_BASE: u32 = 0x4800_0000;
pub const PSRAM_SIZE: usize = 32 * 1024 * 1024;

pub const SRAM_BASE: u32 = 0x4ff0_0000;
pub const SRAM_SIZE: usize = 1 * 1024 * 1024;

pub const FB_WIDTH: usize = 1280;
pub const FB_HEIGHT: usize = 720;
pub const FB_SIZE: usize = FB_WIDTH * FB_HEIGHT * 2; // RGB565LE

pub struct Bus {
    pub flash: Vec<u8>,
    pub psram: Vec<u8>,
    pub sram: Vec<u8>,
    pub mmio: HashMap<u32, u32>,
    pub mmu_table: [u16; 1024],
    pub mmu_index: u16,

    // Simulated peripheral registers / state
    pub timer_ticks: u64,
    pub keyboard_fifo: Vec<u8>,
    pub console_output: Vec<u8>,
}

impl Bus {
    pub fn new() -> Self {
        let mut mmu_table = [0u16; 1024];
        for i in 0..1024 {
            mmu_table[i] = i as u16;
        }

        let mut bus = Self {
            flash: vec![0; FLASH_SIZE],
            psram: vec![0; PSRAM_SIZE],
            sram: vec![0; SRAM_SIZE],
            mmio: HashMap::new(),
            mmu_table,
            mmu_index: 0,
            timer_ticks: 0,
            keyboard_fifo: Vec::with_capacity(256),
            console_output: Vec::with_capacity(4096),
        };

        // Pre-configure initial MMIO registers
        // PMU eFuse trim words for VO2 PSRAM LDO:
        // reg(0x5012d04c): (1 << 8) | (6 << 28) -> calibrated=true, dref=6
        // reg(0x5012d050): (5 << 3)             -> mul=5
        bus.mmio.insert(0x5012_d04c, (1 << 8) | (6 << 28));
        bus.mmio.insert(0x5012_d050, 5 << 3);

        bus
    }

    pub fn framebuffer(&self) -> &[u8] {
        &self.psram[..FB_SIZE]
    }

    pub fn translate_psram(&self, vaddr: u32) -> usize {
        let voff = (vaddr - PSRAM_BASE) as usize;
        let vpage = (voff / 0x1_0000) % 1024;
        let ppage = self.mmu_table[vpage] as usize;
        let poff = (ppage * 0x1_0000) + (voff % 0x1_0000);
        poff % PSRAM_SIZE
    }

    pub fn read_u8(&mut self, addr: u32) -> u8 {
        match addr {
            FLASH_BASE..=0x40ff_ffff => {
                let off = (addr - FLASH_BASE) as usize;
                if off < self.flash.len() { self.flash[off] } else { 0 }
            }
            PSRAM_BASE..=0x49ff_ffff => {
                let off = self.translate_psram(addr);
                self.psram[off]
            }
            SRAM_BASE..=0x4fff_ffff => {
                let off = (addr - SRAM_BASE) as usize;
                if off < self.sram.len() { self.sram[off] } else { 0 }
            }
            0x5000_0000..=0x5fff_ffff => {
                let word_addr = addr & !3;
                let shift = (addr & 3) * 8;
                let word = self.read_mmio_u32(word_addr);
                ((word >> shift) & 0xff) as u8
            }
            _ => 0,
        }
    }

    pub fn read_u16(&mut self, addr: u32) -> u16 {
        let b0 = self.read_u8(addr) as u16;
        let b1 = self.read_u8(addr.wrapping_add(1)) as u16;
        b0 | (b1 << 8)
    }

    pub fn read_u32(&mut self, addr: u32) -> u32 {
        if (0x5000_0000..=0x5fff_ffff).contains(&addr) && (addr & 3) == 0 {
            return self.read_mmio_u32(addr);
        }
        let b0 = self.read_u8(addr) as u32;
        let b1 = self.read_u8(addr.wrapping_add(1)) as u32;
        let b2 = self.read_u8(addr.wrapping_add(2)) as u32;
        let b3 = self.read_u8(addr.wrapping_add(3)) as u32;
        b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    pub fn write_u8(&mut self, addr: u32, val: u8) {
        match addr {
            FLASH_BASE..=0x40ff_ffff => {
                let off = (addr - FLASH_BASE) as usize;
                if off < self.flash.len() { self.flash[off] = val; }
            }
            PSRAM_BASE..=0x49ff_ffff => {
                let off = self.translate_psram(addr);
                self.psram[off] = val;
            }
            SRAM_BASE..=0x4fff_ffff => {
                let off = (addr - SRAM_BASE) as usize;
                if off < self.sram.len() { self.sram[off] = val; }
            }
            0x5000_0000..=0x5fff_ffff => {
                let word_addr = addr & !3;
                let shift = (addr & 3) * 8;
                let mask = !(0xff << shift);
                let cur = self.read_mmio_u32(word_addr);
                let new_val = (cur & mask) | ((val as u32) << shift);
                self.write_mmio_u32(word_addr, new_val);
            }
            _ => {}
        }
    }

    pub fn write_u16(&mut self, addr: u32, val: u16) {
        self.write_u8(addr, val as u8);
        self.write_u8(addr.wrapping_add(1), (val >> 8) as u8);
    }

    pub fn write_u32(&mut self, addr: u32, val: u32) {
        if (0x5000_0000..=0x5fff_ffff).contains(&addr) && (addr & 3) == 0 {
            self.write_mmio_u32(addr, val);
            return;
        }
        self.write_u8(addr, val as u8);
        self.write_u8(addr.wrapping_add(1), (val >> 8) as u8);
        self.write_u8(addr.wrapping_add(2), (val >> 16) as u8);
        self.write_u8(addr.wrapping_add(3), (val >> 24) as u8);
    }

    pub fn read_mmio_u32(&mut self, addr: u32) -> u32 {
        match addr {
            // UART / USB Serial JTAG RX FIFO
            0x5008_4000 => {
                if !self.keyboard_fifo.is_empty() {
                    self.keyboard_fifo.remove(0) as u32
                } else {
                    0
                }
            }
            // UART status: bit 0 = RX FIFO not empty
            0x5008_4004 => {
                if !self.keyboard_fifo.is_empty() { 0x01 } else { 0x00 }
            }
            // Timer Group 0 Counter Low/High (Base: 0x500c_2000)
            0x500c_2004 => (self.timer_ticks & 0xffff_ffff) as u32,
            0x500c_2008 => ((self.timer_ticks >> 32) & 0x003f_ffff) as u32,
            _ => self.mmio.get(&addr).copied().unwrap_or(0),
        }
    }

    pub fn write_mmio_u32(&mut self, addr: u32, val: u32) {
        match addr {
            // UART TX: print character to console output
            0x5008_4000 => {
                let ch = (val & 0xff) as u8;
                if ch != 0 {
                    self.console_output.push(ch);
                }
            }
            // MSPI3 PSRAM Controller (0x5008_f000)
            0x5008_f000 => {
                // When start bit (bit 18) is written, emulate SPI transaction
                if (val & (1 << 18)) != 0 {
                    let spi_addr = self.mmio.get(&0x5008_f004).copied().unwrap_or(0);
                    let user2 = self.mmio.get(&0x5008_f020).copied().unwrap_or(0);
                    let op = user2 & 0xffff; // Operation enum (read_mode=0x4040, write_mode=0xc0c0, read_data=0, write_data=0x8080)
                    let fifo_val = self.mmio.get(&0x5008_f058).copied().unwrap_or(0);

                    match op {
                        // write_mode
                        0xc0c0 => {
                            let reg_key = 0x5008_ff00 | (spi_addr & 0x0f);
                            self.mmio.insert(reg_key, fifo_val);
                        }
                        // read_mode
                        0x4040 => {
                            let reg_key = 0x5008_ff00 | (spi_addr & 0x0f);
                            let default_val = match spi_addr {
                                0 => 0x0d24, // Configuration: APMemory 32MB
                                2 => 0x00c7, // Identity: 32MB, good die (0xc0 | 7)
                                4 => 0x0040, // MR4
                                8 => 0x004b, // MR8
                                _ => 0,
                            };
                            let resp = self.mmio.get(&reg_key).copied().unwrap_or(default_val);
                            self.mmio.insert(0x5008_f058, resp);
                        }
                        // write_data
                        0x8080 => {
                            let psram_off = (spi_addr as usize) % PSRAM_SIZE;
                            let bytes = fifo_val.to_le_bytes();
                            for b in 0..4 {
                                self.psram[(psram_off + b) % PSRAM_SIZE] = bytes[b];
                            }
                        }
                        // read_data (0x0000) or default
                        _ => {
                            let psram_off = (spi_addr as usize) % PSRAM_SIZE;
                            let b0 = self.psram[psram_off] as u32;
                            let b1 = self.psram[(psram_off + 1) % PSRAM_SIZE] as u32;
                            let b2 = self.psram[(psram_off + 2) % PSRAM_SIZE] as u32;
                            let b3 = self.psram[(psram_off + 3) % PSRAM_SIZE] as u32;
                            let resp = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
                            self.mmio.insert(0x5008_f058, resp);
                        }
                    }

                    // Clear start bit (transaction completed immediately)
                    self.mmio.insert(0x5008_f000, val & !(1 << 18));
                    return;
                }
                self.mmio.insert(addr, val);
            }
            // MSPI2 Cache MMU Table (0x5008_e37c / 0x5008_e380)
            0x5008_e380 => {
                self.mmu_index = (val & 0x3ff) as u16;
                self.mmio.insert(addr, val);
            }
            0x5008_e37c => {
                let idx = self.mmu_index as usize;
                if idx < 1024 {
                    if (val & 0xc00) != 0 {
                        self.mmu_table[idx] = (val & 0x3ff) as u16;
                    } else {
                        self.mmu_table[idx] = 0;
                    }
                }
                self.mmio.insert(addr, val);
            }
            // Timer Group 0 update latch (Channel 0: 0x500c_200c, Channel 1: 0x500c_2030)
            0x500c_200c | 0x500c_2030 => {
                // Advance timer ticks to simulate time passing for settle / timeouts
                self.timer_ticks = self.timer_ticks.wrapping_add(150);
                self.mmio.insert(addr, 0); // Writing 1 auto-clears to 0 immediately
            }
            _ => {
                self.mmio.insert(addr, val);
            }
        }
    }
}
