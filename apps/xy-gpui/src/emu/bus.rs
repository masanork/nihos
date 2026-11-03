//! Memory bus and MMIO mapping for ESP32-P4 emulation.
//!
//! Address Map:
//!   0x4000_0000..0x4100_0000 : Flash MMIO (16 MiB)
//!   0x4800_0000..0x4a00_0000 : PSRAM (32 MiB) [0x4803_0000 = Framebuffer 1280x720 RGB565]
//!   0x4fc0_0000..0x4fc1_0000 : Boot ROM (64 KiB)
//!   0x4ff0_0000..0x5000_0000 : SRAM (1 MiB) [0x4ff2_0000 = Text, 0x4ff6_0000 = Stack]
//!   0x8ff0_0000..0x8ffc_0000 : uncached alias of the modeled internal SRAM
//!   0x5000_0000..0x6000_0000 : MMIO Peripherals (MSPI, Timer, UART, PMU, LCD, etc.)

use super::tab5_i2c::Tab5I2c;
use std::collections::HashMap;

pub const FLASH_BASE: u32 = 0x4000_0000;
pub const FLASH_SIZE: usize = 16 * 1024 * 1024;

pub const PSRAM_BASE: u32 = 0x4800_0000;
pub const PSRAM_SIZE: usize = 32 * 1024 * 1024;

pub const SRAM_BASE: u32 = 0x4ff0_0000;
pub const SRAM_SIZE: usize = 1024 * 1024;
pub const SRAM_UNCACHED_BASE: u32 = 0x8ff0_0000;
pub const SRAM_UNCACHED_SIZE: usize = 0xc0000;

pub const FB_WIDTH: usize = 1280;
pub const FB_HEIGHT: usize = 720;
pub const FB_BASE: u32 = 0x4803_0000;
pub const FB_SIZE: usize = FB_WIDTH * FB_HEIGHT * 2; // RGB565LE

pub struct Bus {
    pub flash: Vec<u8>,
    pub psram: Vec<u8>,
    pub sram: Vec<u8>,
    pub tcm: Vec<u8>,
    pub rtc_ram: Vec<u8>,
    pub rom_data: Vec<u8>,
    #[cfg(test)]
    pub(super) rom_flash: Option<super::rom_flash::Flash>,
    #[cfg(test)]
    pub(super) usb_dwc: Option<super::usb_dwc::Usb>,
    pub rom_execute: bool,
    pub rom_executable: Vec<(u32, u32)>,
    pub mmio: HashMap<u32, u32>,
    pub mmu_table: [u16; 1024],
    mmu_raw: [u32; 1024],
    pub(super) mmu_generation: u64,
    pub mmu_index: u16,

    // Simulated peripheral registers / state
    pub timer_ticks: u64,
    pub rom_cpu_mhz: u32,
    systimer_counts: [u64; 2],
    systimer_remainders: [u64; 2],
    systimer_last_ticks: u64,
    systimer_snapshots: [u64; 2],
    systimer_alarm_target: [u64; 3],
    systimer_alarm_armed: [bool; 3],
    systimer_irq_raw: u32,
    pub cpu1_entry: Option<u32>,
    pub cache_l2_mode: Option<(u32, u32, u32)>,
    pub cache_l2_invalidations: u32,
    pub cache_l2_suspended: bool,
    pub cache_l2_autoload: bool,
    pub rom_spi_mode: Option<(u32, u32)>,
    spi1_write_enabled: bool,
    spi1_quad_enabled: bool,
    pub rom_psram_command: Option<super::rom_psram::Command>,
    pub rom_wdt: super::rom_wdt::Watchdog,
    pub fault: Option<String>,
    analog_regs: HashMap<u16, u8>,
    cpll_written: u8,
    i2c: Tab5I2c,
    gpio_enable: u32,
    gpio_enable1: u32,
    scanout: Option<Vec<u8>>,
    pub scanout_frames: u64,
    scanout_revision: u64,
    scanout_fixed_pattern: Option<[u8; 8]>,
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
    #[cfg(test)]
    pub(super) fn use_st7121_fixture(&mut self) {
        self.i2c.set_touch_firmware_version(1);
    }
    pub fn scanout(&self) -> Option<&[u8]> {
        self.scanout.as_deref()
    }

    pub fn scanout_revision(&self) -> u64 {
        self.scanout_revision
    }
    pub fn new() -> Self {
        let mut mmu_table = [0u16; 1024];
        for (i, entry) in mmu_table.iter_mut().enumerate() {
            *entry = i as u16;
        }

        let mut bus = Self {
            flash: vec![0; FLASH_SIZE],
            psram: vec![0; PSRAM_SIZE],
            sram: vec![0; SRAM_SIZE],
            tcm: vec![0; 0x2000],
            rtc_ram: vec![0; 0x8000],
            rom_data: vec![0; 0x2_0000],
            #[cfg(test)]
            rom_flash: None,
            #[cfg(test)]
            usb_dwc: None,
            rom_execute: false,
            rom_executable: Vec::new(),
            mmio: HashMap::new(),
            mmu_table,
            mmu_raw: [0; 1024],
            mmu_generation: 0,
            mmu_index: 0,
            timer_ticks: 0,
            rom_cpu_mhz: 40,
            systimer_counts: [0; 2],
            systimer_remainders: [0; 2],
            systimer_last_ticks: 0,
            systimer_snapshots: [0; 2],
            systimer_alarm_target: [0; 3],
            systimer_alarm_armed: [false; 3],
            systimer_irq_raw: 0,
            cpu1_entry: None,
            cache_l2_mode: None,
            cache_l2_invalidations: 0,
            cache_l2_suspended: false,
            cache_l2_autoload: false,
            rom_spi_mode: None,
            spi1_write_enabled: false,
            spi1_quad_enabled: false,
            rom_psram_command: None,
            rom_wdt: super::rom_wdt::Watchdog::default(),
            fault: None,
            analog_regs: HashMap::new(),
            cpll_written: 0,
            i2c: Tab5I2c::default(),
            gpio_enable: 0,
            gpio_enable1: 0,
            scanout: None,
            scanout_frames: 0,
            scanout_revision: 0,
            scanout_fixed_pattern: None,
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

    pub fn framebuffer_byte(&self, offset: usize) -> Option<u8> {
        assert!(offset < FB_SIZE);
        self.translate_psram(FB_BASE + offset as u32)
            .map(|physical| self.psram[physical])
    }

    pub fn translate_psram(&self, vaddr: u32) -> Option<usize> {
        let voff = vaddr.checked_sub(PSRAM_BASE)? as usize;
        if voff >= PSRAM_SIZE {
            return None;
        }
        let vpage = (voff / 0x1_0000) % 1024;
        let ppage = self.mmu_table[vpage] as usize;
        let poff = (ppage * 0x1_0000) + (voff % 0x1_0000);
        (poff < PSRAM_SIZE).then_some(poff)
    }

    // Supplement a caller's address-range check with cache and PSRAM page
    // validity. Validate every page before a multi-byte ROM operation mutates.
    pub(super) fn mapped_backing_range(&self, address: u32, len: u64) -> bool {
        let start = u64::from(address);
        let Some(end) = start.checked_add(len) else {
            return false;
        };
        if start >= u64::from(PSRAM_BASE) && start < u64::from(PSRAM_BASE) + PSRAM_SIZE as u64 {
            if self.cache_l2_suspended || end > u64::from(PSRAM_BASE) + PSRAM_SIZE as u64 {
                return false;
            }
            if len == 0 {
                return true;
            }
            let first = (start - u64::from(PSRAM_BASE)) / 65536;
            let last = (end - 1 - u64::from(PSRAM_BASE)) / 65536;
            return (first..=last).all(|page| {
                self.translate_psram(PSRAM_BASE + (page as u32) * 65536)
                    .is_some()
            });
        }
        if start >= u64::from(FLASH_BASE) && start < u64::from(FLASH_BASE) + FLASH_SIZE as u64 {
            return !self.cache_l2_suspended && end <= u64::from(FLASH_BASE) + FLASH_SIZE as u64;
        }
        true
    }

    pub fn read_u8(&mut self, addr: u32) -> u8 {
        if self.cache_l2_suspended
            && ((FLASH_BASE..FLASH_BASE + FLASH_SIZE as u32).contains(&addr)
                || (PSRAM_BASE..PSRAM_BASE + PSRAM_SIZE as u32).contains(&addr))
        {
            self.fault.get_or_insert_with(|| {
                format!("cached memory read while L2 suspended: {addr:#010x}")
            });
            return 0;
        }
        match addr {
            0x2080_0000..=0x2080_1fff => self.clic[self.active_hart][(addr - 0x2080_0000) as usize],
            0x3010_0000..=0x3010_1fff => self.tcm[(addr - 0x3010_0000) as usize],
            0x4fc0_0000..=0x4fc1_ffff => self.rom_data[(addr - 0x4fc0_0000) as usize],
            0x5010_8000..=0x5010_ffff => self.rtc_ram[(addr - 0x5010_8000) as usize],
            FLASH_BASE..=0x40ff_ffff => {
                let off = (addr - FLASH_BASE) as usize;
                if off < self.flash.len() {
                    self.flash[off]
                } else {
                    0
                }
            }
            PSRAM_BASE..=0x49ff_ffff => match self.translate_psram(addr) {
                Some(off) => self.psram[off],
                None => {
                    self.fault
                        .get_or_insert_with(|| format!("unmapped PSRAM read: {addr:#010x}"));
                    0
                }
            },
            SRAM_BASE..=0x4fff_ffff => {
                let off = (addr - SRAM_BASE) as usize;
                if off < self.sram.len() {
                    self.sram[off]
                } else {
                    0
                }
            }
            SRAM_UNCACHED_BASE..=0x8ffb_ffff => self.sram[(addr - SRAM_UNCACHED_BASE) as usize],
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
        if (FLASH_BASE..=FLASH_BASE + FLASH_SIZE as u32 - 2).contains(&addr)
            && !self.cache_l2_suspended
        {
            let offset = (addr - FLASH_BASE) as usize;
            return u16::from_le_bytes([self.flash[offset], self.flash[offset + 1]]);
        }
        if (SRAM_BASE..=SRAM_BASE + SRAM_SIZE as u32 - 2).contains(&addr) {
            let offset = (addr - SRAM_BASE) as usize;
            return u16::from_le_bytes([self.sram[offset], self.sram[offset + 1]]);
        }
        if (SRAM_UNCACHED_BASE..=SRAM_UNCACHED_BASE + SRAM_UNCACHED_SIZE as u32 - 2).contains(&addr)
        {
            let offset = (addr - SRAM_UNCACHED_BASE) as usize;
            return u16::from_le_bytes([self.sram[offset], self.sram[offset + 1]]);
        }
        let b0 = self.read_u8(addr) as u16;
        let b1 = self.read_u8(addr.wrapping_add(1)) as u16;
        b0 | (b1 << 8)
    }

    pub fn read_u32(&mut self, addr: u32) -> u32 {
        if (FLASH_BASE..=FLASH_BASE + FLASH_SIZE as u32 - 4).contains(&addr)
            && !self.cache_l2_suspended
        {
            let offset = (addr - FLASH_BASE) as usize;
            return u32::from_le_bytes(self.flash[offset..offset + 4].try_into().unwrap());
        }
        if (SRAM_BASE..=SRAM_BASE + SRAM_SIZE as u32 - 4).contains(&addr) {
            let offset = (addr - SRAM_BASE) as usize;
            return u32::from_le_bytes(self.sram[offset..offset + 4].try_into().unwrap());
        }
        if (SRAM_UNCACHED_BASE..=SRAM_UNCACHED_BASE + SRAM_UNCACHED_SIZE as u32 - 4).contains(&addr)
        {
            let offset = (addr - SRAM_UNCACHED_BASE) as usize;
            return u32::from_le_bytes(self.sram[offset..offset + 4].try_into().unwrap());
        }
        if (0x5000_0000..=0x5fff_ffff).contains(&addr)
            && !(0x5010_8000..=0x5010_ffff).contains(&addr)
            && (addr & 3) == 0
        {
            return self.read_mmio_u32(addr);
        }
        let b0 = self.read_u8(addr) as u32;
        let b1 = self.read_u8(addr.wrapping_add(1)) as u32;
        let b2 = self.read_u8(addr.wrapping_add(2)) as u32;
        let b3 = self.read_u8(addr.wrapping_add(3)) as u32;
        b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    pub fn write_u8(&mut self, addr: u32, val: u8) {
        if self.cache_l2_suspended
            && ((FLASH_BASE..FLASH_BASE + FLASH_SIZE as u32).contains(&addr)
                || (PSRAM_BASE..PSRAM_BASE + PSRAM_SIZE as u32).contains(&addr))
        {
            self.fault.get_or_insert_with(|| {
                format!("cached memory write while L2 suspended: {addr:#010x}")
            });
            return;
        }
        match addr {
            0x2080_0000..=0x2080_1fff => {
                self.clic[self.active_hart][(addr - 0x2080_0000) as usize] = val
            }
            0x3010_0000..=0x3010_1fff => self.tcm[(addr - 0x3010_0000) as usize] = val,
            0x5010_8000..=0x5010_ffff => self.rtc_ram[(addr - 0x5010_8000) as usize] = val,
            FLASH_BASE..=0x40ff_ffff => {
                let off = (addr - FLASH_BASE) as usize;
                if off < self.flash.len() {
                    self.flash[off] = val;
                }
            }
            PSRAM_BASE..=0x49ff_ffff => match self.translate_psram(addr) {
                Some(off) => self.psram[off] = val,
                None => {
                    self.fault
                        .get_or_insert_with(|| format!("unmapped PSRAM write: {addr:#010x}"));
                }
            },
            SRAM_BASE..=0x4fff_ffff => {
                let off = (addr - SRAM_BASE) as usize;
                if off < self.sram.len() {
                    self.sram[off] = val;
                }
            }
            SRAM_UNCACHED_BASE..=0x8ffb_ffff => {
                self.sram[(addr - SRAM_UNCACHED_BASE) as usize] = val
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
        if (0x5000_0000..=0x5fff_ffff).contains(&addr)
            && !(0x5010_8000..=0x5010_ffff).contains(&addr)
            && (addr & 3) == 0
        {
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
        if self.cache_l2_suspended
            || dst != 0x5010_5000
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
        let mut next_fixed_pattern = None;
        let pixels = if fixed {
            let mut pattern = [0u8; 8];
            for (i, pixel) in pattern.iter_mut().enumerate() {
                let Some(physical) = self.translate_psram(src + i as u32) else {
                    return;
                };
                *pixel = self.psram[physical];
            }
            if self.scanout_fixed_pattern == Some(pattern) && self.scanout.is_some() {
                self.finish_display_dma();
                return;
            }
            next_fixed_pattern = Some(pattern);
            let mut frame = vec![0; FB_SIZE];
            for chunk in frame.chunks_exact_mut(width) {
                chunk.copy_from_slice(&pattern);
            }
            Some(frame)
        } else {
            let mut candidate: Option<Vec<u8>> = None;
            let mut offset = 0;
            while offset < FB_SIZE {
                let address = src + offset as u32;
                let Some(physical) = self.translate_psram(address) else {
                    return;
                };
                let page_remaining = 65536 - (address as usize & 65535);
                let count = page_remaining
                    .min(FB_SIZE - offset)
                    .min(PSRAM_SIZE - physical);
                let source = &self.psram[physical..physical + count];
                if candidate.is_none()
                    && self
                        .scanout
                        .as_ref()
                        .is_none_or(|old| old[offset..offset + count] != *source)
                {
                    let mut frame = vec![0; FB_SIZE];
                    if let Some(old) = &self.scanout {
                        frame[..offset].copy_from_slice(&old[..offset]);
                    }
                    candidate = Some(frame);
                }
                if let Some(frame) = &mut candidate {
                    frame[offset..offset + count].copy_from_slice(source);
                }
                offset += count;
            }
            candidate
        };
        if let Some(pixels) = pixels
            && self.scanout.as_ref() != Some(&pixels)
        {
            self.scanout = Some(pixels);
            self.scanout_revision = self.scanout_revision.wrapping_add(1);
        }
        self.scanout_fixed_pattern = next_fixed_pattern;
        self.finish_display_dma();
    }

    fn finish_display_dma(&mut self) {
        self.dma_primed = true;
        self.scanout_frames += 1;
        self.dma_irq |= 2;
        self.dma_ready_at = self.timer_ticks + 1_000_000;
    }

    fn display_dma_interrupt_active(&self) -> bool {
        self.dma_irq != 0
            && self.timer_ticks >= self.dma_ready_at
            && self.mmio.get(&0x5008_1190).copied().unwrap_or(0) & self.dma_irq != 0
    }

    fn timer_counter(&self, channel: usize) -> u64 {
        self.timer_ticks.saturating_sub(self.timer_epoch[channel]) / 360
    }

    fn sync_systimer(&mut self) {
        let elapsed = self.timer_ticks.wrapping_sub(self.systimer_last_ticks);
        self.systimer_last_ticks = self.timer_ticks;
        let config = self.mmio.get(&0x500e_2000).copied().unwrap_or(0);
        for counter in 0..2 {
            if config & (1 << (30 - counter)) != 0 {
                // Existing bus time is 360 ticks/us; P4 SYSTIMER is 16 ticks/us.
                let scaled =
                    u128::from(elapsed) * 16 + u128::from(self.systimer_remainders[counter]);
                self.systimer_counts[counter] = self.systimer_counts[counter]
                    .wrapping_add((scaled / 360) as u64)
                    & ((1u64 << 52) - 1);
                self.systimer_remainders[counter] = (scaled % 360) as u64;
            }
        }
        for alarm in 0..3 {
            let conf = self
                .mmio
                .get(&(0x500e_2034 + alarm as u32 * 4))
                .copied()
                .unwrap_or(0);
            let counter = ((conf >> 31) & 1) as usize;
            if self.systimer_alarm_armed[alarm]
                && config & (1 << (24 - alarm)) != 0
                && config & (1 << (30 - counter)) != 0
                && conf & (1 << 30) == 0
                && self.systimer_counts[counter] >= self.systimer_alarm_target[alarm]
            {
                self.systimer_irq_raw |= 1 << alarm;
                self.systimer_alarm_armed[alarm] = false;
            }
        }
    }

    pub fn irq_vectored(&self, hart: usize, line: u32) -> bool {
        hart < 2 && line < 64 && self.clic[hart][0x1000 + line as usize * 4 + 2] & 1 != 0
    }

    // Timer status is peripheral state: it latches at the deadline even when
    // CPU interrupts are masked and no interrupt-delivery poll takes place.
    fn update_timer_alarms(&mut self) {
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
    }

    pub fn pending_irq(&mut self, hart: usize) -> Option<u32> {
        if hart >= 2 {
            return None;
        }
        self.sync_systimer();
        self.update_timer_alarms();
        let enabled = |line: usize| self.clic[hart][0x1000 + line * 4 + 1] & 1 != 0;
        let matrix = 0x500d_6000 + hart as u32 * 0x800;
        let routed =
            |source: u32, line: u32| self.mmio.get(&(matrix + source * 4)).copied() == Some(line);
        let timer_enabled = self.mmio.get(&0x500e_2064).copied().unwrap_or(0);
        for alarm in 0..3 {
            let line = self
                .mmio
                .get(&(matrix + (53 + alarm) * 4))
                .copied()
                .unwrap_or(0);
            if (16..48).contains(&line)
                && enabled(line as usize)
                && self.systimer_irq_raw & timer_enabled & (1 << alarm) != 0
            {
                return Some(line);
            }
        }
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
        let dma_line = self.mmio.get(&(matrix + 24 * 4)).copied().unwrap_or(0);
        if (16..48).contains(&dma_line)
            && enabled(dma_line as usize)
            && self.mmio.get(&0x5008_1010).copied().unwrap_or(0) & 2 != 0
            && self.display_dma_interrupt_active()
        {
            return Some(dma_line);
        }
        None
    }

    pub fn read_mmio_u32(&mut self, addr: u32) -> u32 {
        #[cfg(test)]
        if (0x5000_0000..0x5000_1000).contains(&addr)
            && let Some(usb) = &mut self.usb_dwc
        {
            return match usb.read(addr - 0x5000_0000) {
                Ok(value) => value,
                Err(error) => {
                    self.fault = Some(error);
                    0
                }
            };
        }
        match addr {
            0x5008_e37c => self.mmu_raw[self.mmu_index as usize],
            0x500e_2068 => {
                self.sync_systimer();
                self.systimer_irq_raw
            }
            0x500e_2070 => {
                self.sync_systimer();
                self.systimer_irq_raw & self.mmio.get(&0x500e_2064).copied().unwrap_or(0)
            }
            0x500e_2040 => (self.systimer_snapshots[0] >> 32) as u32,
            0x500e_2044 => self.systimer_snapshots[0] as u32,
            0x500e_2048 => (self.systimer_snapshots[1] >> 32) as u32,
            0x500e_204c => self.systimer_snapshots[1] as u32,
            // Functional DSI model: immediate PLL lock and drained command FIFOs.
            0x500a_00b0 => 0x95,
            0x5008_1030 => u32::from(self.display_dma_interrupt_active()),
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
            0x500c_2078 => {
                self.update_timer_alarms();
                self.timer_irq
            }
            _ => self.mmio.get(&addr).copied().unwrap_or(0),
        }
    }

    pub fn write_mmio_u32(&mut self, addr: u32, val: u32) {
        #[cfg(test)]
        if (0x5000_0000..0x5000_1000).contains(&addr)
            && let Some(usb) = &mut self.usb_dwc
        {
            if let Err(error) = usb.write(addr - 0x5000_0000, val) {
                self.fault = Some(error);
            }
            return;
        }
        match addr {
            // Functional DW-GDMA software reset: clear the modeled controller
            // registers and pending completion, then self-clear the reset bit.
            0x5008_1058 => {
                if val & 1 != 0 {
                    self.mmio
                        .retain(|address, _| !(0x5008_1000..0x5008_1800).contains(address));
                    self.dma_irq = 0;
                    self.dma_primed = false;
                    self.dma_ready_at = 0;
                }
            }
            0x500e_2050 | 0x500e_2054 | 0x500e_2058 => {
                let alarm = ((addr - 0x500e_2050) / 4) as usize;
                if val & 1 != 0 {
                    self.sync_systimer();
                    let hi = self
                        .mmio
                        .get(&(0x500e_201c + alarm as u32 * 8))
                        .copied()
                        .unwrap_or(0)
                        & 0xfffff;
                    let lo = self
                        .mmio
                        .get(&(0x500e_2020 + alarm as u32 * 8))
                        .copied()
                        .unwrap_or(0);
                    self.systimer_alarm_target[alarm] = (u64::from(hi) << 32) | u64::from(lo);
                    self.systimer_alarm_armed[alarm] = true;
                }
            }
            0x500e_2068 | 0x500e_206c => self.systimer_irq_raw &= !(val & 7),
            0x500e_2000 => {
                self.sync_systimer();
                self.mmio.insert(addr, val);
            }
            0x500e_2004 | 0x500e_2008 => {
                let counter = usize::from(addr == 0x500e_2008);
                let mut state = self.mmio.get(&addr).copied().unwrap_or(0);
                if val & (1 << 29) != 0 {
                    state &= !(1 << 29);
                }
                if val & (1 << 30) != 0 {
                    self.sync_systimer();
                    self.systimer_snapshots[counter] = self.systimer_counts[counter];
                    state |= 1 << 29;
                }
                self.mmio.insert(addr, state);
            }
            // Stopping CPLL calibration invalidates the current completion.
            0x500e_60bc => {
                let next = if val & (1 << 3) != 0 {
                    self.cpll_written = 0;
                    val & !(1 << 2)
                } else {
                    val
                };
                self.mmio.insert(addr, next);
            }
            // Functional clock-divider commit: hardware self-clears UPDATE.
            0x500e_6004 => {
                self.mmio.insert(addr, val & !(1 << 4));
            }
            // Functional TIMG0 one-shot RC_SLOW calibration, not oscillator timing.
            0x500c_2068 => {
                let prev = self.mmio.get(&addr).copied().unwrap_or(0);
                let mut next = val & !(1 << 15);
                if val & (1 << 31) != 0 && prev & (1 << 31) == 0 {
                    let selector = self.mmio.get(&0x500e_6098).copied().unwrap_or(0);
                    let cycles = (val >> 16) & 0x7fff;
                    if selector & 0x000f_ffff != 8 || cycles == 0 || val & (1 << 12) != 0 {
                        self.fault = Some(format!(
                            "unsupported RTC calibration selector={selector:#010x} cycles={cycles} cfg={val:#010x}"
                        ));
                    } else {
                        let xtal_cycles = (u64::from(cycles) * 40_000_000 / 136_000) as u32;
                        self.mmio.insert(0x500c_206c, xtal_cycles << 7);
                        next |= 1 << 15;
                    }
                } else if val & (1 << 31) != 0 {
                    next |= prev & (1 << 15);
                }
                self.mmio.insert(addr, next);
            }
            // Functional SPI1 responses for the synthetic 16 MiB NOR.
            // Synthetic status: WEL and the status-register-2 QE bit only.
            // Programming, erasing and other status bits are not modeled.
            0x5008_d000 if val != 0 => {
                let user = self.mmio.get(&0x5008_d018).copied().unwrap_or(0);
                let command = self.mmio.get(&0x5008_d020).copied().unwrap_or(0);
                let mosi_bits = self.mmio.get(&0x5008_d024).copied().unwrap_or(0) & 0x3ff;
                let miso_bits = self.mmio.get(&0x5008_d028).copied().unwrap_or(0) & 0x3ff;
                if val == 1 << 30 || val == 1 << 29 {
                    self.spi1_write_enabled = val == 1 << 30;
                    self.mmio.insert(addr, 0);
                } else if val == 1 << 18
                    && user == 0x9000_0000
                    && command == 0x7000_009f
                    && miso_bits == 23
                {
                    self.mmio.insert(0x5008_d058, 0x0018_40ef);
                    self.mmio.insert(addr, 0);
                } else if val == 1 << 18
                    && user == 0x9000_0000
                    && matches!(command, 0x7000_0005 | 0x7000_0035)
                    && miso_bits == 7
                {
                    let status = match command {
                        0x7000_0005 => u32::from(self.spi1_write_enabled) << 1,
                        _ => u32::from(self.spi1_quad_enabled) << 1,
                    };
                    self.mmio.insert(0x5008_d058, status);
                    self.mmio.insert(addr, 0);
                } else if val == 1 << 18
                    && user == 0x8800_0000
                    && command == 0x7000_0001
                    && mosi_bits == 15
                    && self.spi1_write_enabled
                    && self.mmio.get(&0x5008_d058).copied().unwrap_or(0) & 0xffff_fdff == 0
                {
                    let status = self.mmio.get(&0x5008_d058).copied().unwrap_or(0);
                    self.spi1_quad_enabled = status & 0x200 != 0;
                    self.spi1_write_enabled = false;
                    self.mmio.insert(addr, 0);
                } else {
                    self.fault = Some(format!(
                        "unsupported SPI1 command cmd={val:#010x} user={user:#010x} user2={command:#010x} miso={miso_bits}"
                    ));
                }
            }
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
                let block = (val & 0xff) as u8;
                let index = ((val >> 8) & 0xff) as u8;
                let key = (u16::from(block) << 8) | u16::from(index);
                if val & (1 << 24) != 0 {
                    self.analog_regs.insert(key, (val >> 16) as u8);
                    if block == 0x63 && index == 2 {
                        *self.mmio.entry(0x500e_60bc).or_default() |= 1 << 8;
                    }
                    if block == 0x67 {
                        self.cpll_written |= match index {
                            2 => 1,
                            3 => 2,
                            6 => 4,
                            _ => 0,
                        };
                        let ctrl = self.mmio.entry(0x500e_60bc).or_default();
                        if self.cpll_written == 7 && *ctrl & (1 << 3) == 0 {
                            *ctrl |= 1 << 2;
                        }
                    }
                }
                self.mmio.insert(
                    addr,
                    u32::from(*self.analog_regs.get(&key).unwrap_or(&0)) << 16,
                );
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
                    self.mmu_generation = self.mmu_generation.wrapping_add(1);
                    self.mmu_raw[idx] = val;
                    if (val & 0xc00) == 0xc00 && val & (1 << 12) == 0 {
                        self.mmu_table[idx] = (val & 0x3ff) as u16;
                    } else {
                        self.mmu_table[idx] = u16::MAX;
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
