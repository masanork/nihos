//! Memory bus and MMIO mapping for ESP32-P4 emulation.
//!
//! Address Map:
//!   0x4000_0000..0x4100_0000 : Flash MMIO (16 MiB)
//!   0x4800_0000..0x4a00_0000 : PSRAM (32 MiB) [0x4803_0000 = Framebuffer 1280x720 RGB565]
//!   0x4fc0_0000..0x4fc1_0000 : Boot ROM (64 KiB)
//!   0x4ff0_0000..0x5000_0000 : SRAM (1 MiB) [0x4ff2_0000 = Text, 0x4ff6_0000 = Stack]
//!   0x5000_0000..0x6000_0000 : MMIO Peripherals (MSPI, Timer, UART, PMU, LCD, etc.)

use super::tab5_i2c::Tab5I2c;
use std::collections::HashMap;

pub const FLASH_BASE: u32 = 0x4000_0000;
pub const FLASH_SIZE: usize = 16 * 1024 * 1024;

pub const PSRAM_BASE: u32 = 0x4800_0000;
pub const PSRAM_SIZE: usize = 32 * 1024 * 1024;

pub const SRAM_BASE: u32 = 0x4ff0_0000;
pub const SRAM_SIZE: usize = 1024 * 1024;

pub const FB_WIDTH: usize = 1280;
pub const FB_HEIGHT: usize = 720;
pub const FB_BASE: u32 = 0x4803_0000;
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
    pub cpu1_entry: Option<u32>,
    analog_regs: [u8; 256],
    i2c: Tab5I2c,
    gpio_enable: u32,
    gpio_enable1: u32,
    pub scanout: Option<Vec<u8>>,
    pub scanout_frames: u64,
    dma_irq: u32,
    dma_primed: bool,
    dma_ready_at: u64,
    pub active_hart: usize,
    clic: [Vec<u8>; 2],
    timer_epoch: [u64; 2],
    timer_irq: u32,
    pub keyboard_fifo: Vec<u8>,
    pub console_output: Vec<u8>,
}

impl Default for Bus {
    fn default() -> Self {
        Self::new()
    }
}

impl Bus {
    pub fn new() -> Self {
        let mut mmu_table = [0u16; 1024];
        for (i, entry) in mmu_table.iter_mut().enumerate() {
            *entry = i as u16;
        }

        let mut bus = Self {
            flash: vec![0; FLASH_SIZE],
            psram: vec![0; PSRAM_SIZE],
            sram: vec![0; SRAM_SIZE],
            mmio: HashMap::new(),
            mmu_table,
            mmu_index: 0,
            timer_ticks: 0,
            cpu1_entry: None,
            analog_regs: [0; 256],
            i2c: Tab5I2c::default(),
            gpio_enable: 0,
            gpio_enable1: 0,
            scanout: None,
            scanout_frames: 0,
            dma_irq: 0,
            dma_primed: false,
            dma_ready_at: 0,
            active_hart: 0,
            clic: [vec![0; 8192], vec![0; 8192]],
            timer_epoch: [0; 2],
            timer_irq: 0,
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

    pub fn touch(&mut self, point: Option<(u16, u16)>) {
        self.i2c.touch(point);
    }

    pub fn framebuffer_byte(&self, offset: usize) -> u8 {
        assert!(offset < FB_SIZE);
        self.psram[self.translate_psram(FB_BASE + offset as u32)]
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
            0x2080_0000..=0x2080_1fff => self.clic[self.active_hart][(addr - 0x2080_0000) as usize],
            FLASH_BASE..=0x40ff_ffff => {
                let off = (addr - FLASH_BASE) as usize;
                if off < self.flash.len() {
                    self.flash[off]
                } else {
                    0
                }
            }
            PSRAM_BASE..=0x49ff_ffff => {
                let off = self.translate_psram(addr);
                self.psram[off]
            }
            SRAM_BASE..=0x4fff_ffff => {
                let off = (addr - SRAM_BASE) as usize;
                if off < self.sram.len() {
                    self.sram[off]
                } else {
                    0
                }
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
            0x2080_0000..=0x2080_1fff => {
                self.clic[self.active_hart][(addr - 0x2080_0000) as usize] = val
            }
            FLASH_BASE..=0x40ff_ffff => {
                let off = (addr - FLASH_BASE) as usize;
                if off < self.flash.len() {
                    self.flash[off] = val;
                }
            }
            PSRAM_BASE..=0x49ff_ffff => {
                let off = self.translate_psram(addr);
                self.psram[off] = val;
            }
            SRAM_BASE..=0x4fff_ffff => {
                let off = (addr - SRAM_BASE) as usize;
                if off < self.sram.len() {
                    self.sram[off] = val;
                }
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

    // A bounded, single-descriptor transfer to the DSI FIFO. Unsupported
    // descriptors do not publish pixels or a completion interrupt.
    fn start_display_dma(&mut self) {
        self.dma_irq = 0;
        self.dma_primed = false;
        let head = self.mmio.get(&0x5008_1128).copied().unwrap_or(0) & !63;
        if !(SRAM_BASE..=SRAM_BASE + SRAM_SIZE as u32 - 64).contains(&head) {
            return;
        }
        let src = self.read_u32(head);
        let dst = self.read_u32(head + 8);
        let count = (self.read_u32(head + 16) & 0x3f_ffff) as usize + 1;
        let next = self.read_u32(head + 24) & !63;
        let ctrl = self.read_u32(head + 32);
        let markers = self.read_u32(head + 36);
        let width = 1usize << ((ctrl >> 8) & 7);
        let fixed = ctrl & (1 << 4) != 0;
        if dst != 0x5010_5000
            || next != 0
            || markers & 0xc000_0000 != 0xc000_0000
            || count.checked_mul(width) != Some(FB_SIZE)
            || width != 8
            || src < PSRAM_BASE
            || src
                .checked_add(if fixed { width as u32 } else { FB_SIZE as u32 })
                .is_none_or(|end| end > PSRAM_BASE + PSRAM_SIZE as u32)
        {
            return;
        }
        let mut pixels = vec![0; FB_SIZE];
        if fixed {
            for chunk in pixels.chunks_exact_mut(width) {
                for (i, pixel) in chunk.iter_mut().enumerate() {
                    *pixel = self.psram[self.translate_psram(src + i as u32)];
                }
            }
        } else {
            let mut offset = 0;
            while offset < FB_SIZE {
                let address = src + offset as u32;
                let physical = self.translate_psram(address);
                let page_remaining = 65536 - (address as usize & 65535);
                let count = page_remaining
                    .min(FB_SIZE - offset)
                    .min(PSRAM_SIZE - physical);
                pixels[offset..offset + count]
                    .copy_from_slice(&self.psram[physical..physical + count]);
                offset += count;
            }
        }
        self.scanout = Some(pixels);
        self.dma_primed = true;
        self.scanout_frames += 1;
        self.dma_irq |= 2;
        self.dma_ready_at = self.timer_ticks + 1_000_000;
    }

    fn timer_counter(&self, channel: usize) -> u64 {
        self.timer_ticks.saturating_sub(self.timer_epoch[channel]) / 360
    }

    pub fn pending_irq(&mut self, hart: usize) -> Option<u32> {
        if hart >= 2 {
            return None;
        }
        for channel in 0..2 {
            let base = 0x500c_2000 + channel as u32 * 0x24;
            let cfg = self.mmio.get(&base).copied().unwrap_or(0);
            let alarm = self.mmio.get(&(base + 0x10)).copied().unwrap_or(0) as u64
                | ((self.mmio.get(&(base + 0x14)).copied().unwrap_or(0) as u64) << 32);
            if cfg & (1 << 31 | 1 << 10) == (1 << 31 | 1 << 10)
                && self.timer_counter(channel) >= alarm
            {
                self.timer_irq |= 1 << channel;
                self.mmio.insert(base, cfg & !(1 << 10));
            }
        }
        let enabled = |line: usize| self.clic[hart][0x1000 + line * 4 + 1] & 1 != 0;
        let matrix = 0x500d_6000 + hart as u32 * 0x800;
        let routed =
            |source: u32, line: u32| self.mmio.get(&(matrix + source * 4)).copied() == Some(line);
        if enabled(17)
            && routed(79 + hart as u32, 17)
            && self
                .mmio
                .get(&(0x500e_5010 + hart as u32 * 4))
                .copied()
                .unwrap_or(0)
                & 1
                != 0
        {
            return Some(17);
        }
        if enabled(16)
            && routed(46 + hart as u32, 16)
            && self.timer_irq & (1 << hart) != 0
            && self.mmio.get(&0x500c_2070).copied().unwrap_or(0) & (1 << hart) != 0
        {
            return Some(16);
        }
        if hart == 0
            && enabled(18)
            && self.dma_irq != 0
            && self.timer_ticks >= self.dma_ready_at
            && self.mmio.get(&0x5008_1190).copied().unwrap_or(0) & 2 != 0
        {
            return Some(18);
        }
        None
    }

    pub fn read_mmio_u32(&mut self, addr: u32) -> u32 {
        match addr {
            // Functional DSI model: immediate PLL lock and drained command FIFOs.
            0x500a_00b0 => 0x95,
            0x500a_0814 => {
                if self.dma_primed {
                    1024
                } else {
                    0
                }
            }
            0x5008_1188 => {
                if self.timer_ticks >= self.dma_ready_at {
                    self.dma_irq
                } else {
                    0
                }
            }
            0x5008_1018 => 0,
            0x500a_0074 => 0x0005_0015,
            0x500e_0020 => self.gpio_enable,
            0x500e_002c => self.gpio_enable1,
            0x500e_003c => {
                // GPIO 0/1 are the separate, disconnected keyboard I2C bus.
                // Pull-ups hold each released open-drain line high; no slave
                // pulls SDA low to acknowledge an address.
                let keyboard_lines = !self.gpio_enable & 3;
                keyboard_lines | if self.i2c.data_high() { 1 << 31 } else { 0 }
            }
            0x500e_0040 => u32::from(self.i2c.clock_high()),
            0x500d_2000 => {
                if self.keyboard_fifo.is_empty() {
                    0
                } else {
                    self.keyboard_fifo.remove(0) as u32
                }
            }
            0x500d_2004 => 2 | if self.keyboard_fifo.is_empty() { 0 } else { 4 },
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
                if !self.keyboard_fifo.is_empty() {
                    0x01
                } else {
                    0x00
                }
            }
            // Timer Group 0 Counter Low/High (Base: 0x500c_2000)
            0x500c_2004 => self.timer_counter(0) as u32,
            0x500c_2008 => (self.timer_counter(0) >> 32) as u32,
            0x500c_2028 => self.timer_counter(1) as u32,
            0x500c_202c => (self.timer_counter(1) >> 32) as u32,
            0x500c_3004 => (self.timer_ticks / 360) as u32,
            0x500c_3008 => ((self.timer_ticks / 360) >> 32) as u32,
            0x500c_2078 => self.timer_irq,
            _ => self.mmio.get(&addr).copied().unwrap_or(0),
        }
    }

    pub fn write_mmio_u32(&mut self, addr: u32, val: u32) {
        match addr {
            0x500c_2020 | 0x500c_2044 => {
                let channel = usize::from(addr == 0x500c_2044);
                self.timer_epoch[channel] = self.timer_ticks;
                self.mmio.insert(addr, val);
            }
            0x500c_207c => self.timer_irq &= !val,
            0x5008_1018 => {
                if val & 0x101 == 0x101 {
                    self.start_display_dma();
                }
            }
            0x5008_1198 => {
                self.dma_irq &= !val;
            }
            0x500e_0020 | 0x500e_0024 | 0x500e_0028 | 0x500e_002c | 0x500e_0030 | 0x500e_0034 => {
                match addr {
                    0x500e_0020 => self.gpio_enable = val,
                    0x500e_0024 => self.gpio_enable |= val,
                    0x500e_0028 => self.gpio_enable &= !val,
                    0x500e_002c => self.gpio_enable1 = val,
                    0x500e_0030 => self.gpio_enable1 |= val,
                    _ => self.gpio_enable1 &= !val,
                }
                self.i2c.set_lines(
                    self.gpio_enable1 & 1 == 0,
                    self.gpio_enable & (1 << 31) == 0,
                );
            }
            // USB Serial/JTAG and legacy UART TX.
            0x500d_2000 | 0x5008_4000 => {
                let ch = (val & 0xff) as u8;
                if ch != 0 {
                    self.console_output.push(ch);
                }
            }
            // MPLL analog register transactions and calibration completion.
            0x5012_4000 => {
                let index = ((val >> 8) & 0xff) as usize;
                if val & (1 << 24) != 0 {
                    self.analog_regs[index] = (val >> 16) as u8;
                    if index == 2 {
                        *self.mmio.entry(0x500e_60bc).or_default() |= 1 << 8;
                    }
                }
                self.mmio
                    .insert(addr, (self.analog_regs[index] as u32) << 16);
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
                            for (b, &byte) in bytes.iter().enumerate() {
                                self.psram[(psram_off + b) % PSRAM_SIZE] = byte;
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
            0x500c_200c | 0x500c_2030 | 0x500c_300c => {
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
