//! Experimental direct application loading. This does not emulate the ROM or bootloader.
use super::bus::Bus;
use sha2::{Digest, Sha256};
use std::io::{Error, ErrorKind, Result};
use std::path::Path;

fn invalid(message: &'static str) -> Error {
    Error::new(ErrorKind::InvalidData, message)
}

/// Copy only ROM PT_LOAD file bytes. The ROM ELF omits the final layout pointer,
/// so callers must supply the layout symbol from that exact ROM build.
pub(super) fn load_rom_data(bus: &mut Bus, path: impl AsRef<Path>, layout: u32) -> Result<()> {
    let data = std::fs::read(path)?;
    if data.len() < 52
        || &data[..6] != b"\x7fELF\x01\x01"
        || u16::from_le_bytes([data[18], data[19]]) != 243
    {
        return Err(invalid("invalid RISC-V ROM ELF"));
    }
    let phoff = u32::from_le_bytes(data[28..32].try_into().unwrap()) as usize;
    let phsize = u16::from_le_bytes(data[42..44].try_into().unwrap()) as usize;
    let phnum = u16::from_le_bytes(data[44..46].try_into().unwrap()) as usize;
    if phsize < 32 || phnum == 0 {
        return Err(invalid("invalid ROM ELF program headers"));
    }
    let mut rom = vec![0; 0x20000];
    let mut loaded = Vec::<(usize, usize)>::new();
    let mut executable = Vec::new();
    for i in 0..phnum {
        let offset = phoff
            .checked_add(
                i.checked_mul(phsize)
                    .ok_or_else(|| invalid("ROM header overflow"))?,
            )
            .ok_or_else(|| invalid("ROM header overflow"))?;
        let h = data
            .get(
                offset
                    ..offset
                        .checked_add(32)
                        .ok_or_else(|| invalid("ROM header overflow"))?,
            )
            .ok_or_else(|| invalid("truncated ROM header"))?;
        if u32::from_le_bytes(h[..4].try_into().unwrap()) != 1 {
            continue;
        }
        let file = u32::from_le_bytes(h[4..8].try_into().unwrap()) as usize;
        let address = u32::from_le_bytes(h[8..12].try_into().unwrap());
        let size = u32::from_le_bytes(h[16..20].try_into().unwrap()) as usize;
        let flags = u32::from_le_bytes(h[24..28].try_into().unwrap());
        if size == 0 || !(0x4fc0_0000..0x4fc2_0000).contains(&address) {
            continue;
        }
        let dst = (address - 0x4fc0_0000) as usize;
        let end = dst
            .checked_add(size)
            .filter(|&n| n <= rom.len())
            .ok_or_else(|| invalid("ROM segment out of range"))?;
        let source_end = file
            .checked_add(size)
            .ok_or_else(|| invalid("ROM segment overflow"))?;
        let source = data
            .get(file..source_end)
            .ok_or_else(|| invalid("truncated ROM segment"))?;
        if loaded.iter().any(|&(a, b)| dst < b && a < end) {
            return Err(invalid("overlapping ROM segments"));
        }
        rom[dst..end].copy_from_slice(source);
        loaded.push((dst, end));
        if flags & 1 != 0 {
            executable.push((address, 0x4fc0_0000 + end as u32));
        }
    }
    let layout_offset = layout
        .checked_sub(0x4fc0_0000)
        .ok_or_else(|| invalid("ROM layout out of range"))? as usize;
    if layout & 3 != 0
        || !loaded.iter().any(|&(a, b)| {
            layout_offset >= a && layout_offset.checked_add(8).is_some_and(|end| end <= b)
        })
    {
        return Err(invalid("ROM layout not in loaded ROM"));
    }
    let reserved = u32::from_le_bytes(
        rom[layout_offset + 4..layout_offset + 8]
            .try_into()
            .unwrap(),
    );
    if !(0x4ff0_0000..=0x4ff4_0000).contains(&reserved) {
        return Err(invalid("invalid ROM reserved RAM boundary"));
    }
    rom[0x1fffc..].copy_from_slice(&layout.to_le_bytes());
    bus.rom_data = rom;
    bus.rom_executable = executable;
    Ok(())
}

/// Validate an ESP32-P4 app image completely before changing guest memory.
/// Flash segments are copied to their image virtual pages; this is not a Flash MMU.
pub fn load(bus: &mut Bus, path: impl AsRef<Path>) -> Result<u32> {
    let data = std::fs::read(path)?;
    if data.len() < 24 || data[0] != 0xe9 || !(1..=16).contains(&data[1]) {
        return Err(invalid("invalid ESP image header"));
    }
    if u16::from_le_bytes([data[12], data[13]]) != 18 {
        return Err(invalid("image is not for ESP32-P4"));
    }
    let entry = u32::from_le_bytes(data[4..8].try_into().unwrap());
    let mut offset = 24usize;
    let mut segments = Vec::new();
    let mut checksum = 0xefu8;
    for _ in 0..data[1] {
        let header = data
            .get(offset..offset + 8)
            .ok_or_else(|| invalid("truncated segment header"))?;
        let address = u32::from_le_bytes(header[..4].try_into().unwrap());
        let size = u32::from_le_bytes(header[4..].try_into().unwrap()) as usize;
        offset += 8;
        let end = offset
            .checked_add(size)
            .ok_or_else(|| invalid("segment size overflow"))?;
        let bytes = data
            .get(offset..end)
            .ok_or_else(|| invalid("truncated segment"))?;
        let segment_end = (address as u64) + size as u64;
        let allowed = [
            (0x3010_0000u64, 0x3010_2000u64),
            (0x4000_0000, 0x4100_0000),
            (0x4ff0_0000, 0x5000_0000),
            (0x5010_8000, 0x5011_0000),
        ]
        .iter()
        .any(|&(start, end)| address as u64 >= start && segment_end <= end);
        if size == 0
            || !allowed
            || segments
                .iter()
                .any(|&(start, end, _, _)| (address as u64) < end && start < segment_end)
        {
            return Err(invalid("unmapped or overlapping ESP image segment"));
        }
        checksum = bytes.iter().fold(checksum, |sum, byte| sum ^ byte);
        segments.push((address as u64, segment_end, offset, end));
        offset = end;
    }
    let checksum_end = offset
        .checked_add(16)
        .ok_or_else(|| invalid("checksum offset overflow"))?
        & !15;
    if data.get(checksum_end - 1).copied() != Some(checksum) {
        return Err(invalid("ESP image checksum mismatch"));
    }
    match data[23] {
        0 if data.len() == checksum_end => {}
        1 if data.len() == checksum_end + 32
            && Sha256::digest(&data[..checksum_end]).as_slice() == &data[checksum_end..] => {}
        _ => return Err(invalid("ESP image digest or trailing data mismatch")),
    }
    if !segments
        .iter()
        .any(|&(start, end, _, _)| (entry as u64) >= start && (entry as u64) < end)
    {
        return Err(invalid("entry outside loaded segments"));
    }
    // The app header and segment headers can be read via the same mapped
    // 64 KiB flash page as a segment. Construct a static page view of the app
    // file, checking the IDF alignment contract and conflicting page maps.
    let mut flash_pages: Vec<(usize, usize)> = Vec::new();
    for &(address, _, begin, end) in &segments {
        if !(0x4000_0000..0x4100_0000).contains(&address) {
            continue;
        }
        let virtual_offset = (address - 0x4000_0000) as usize;
        if (virtual_offset & 0xffff) != (begin & 0xffff) {
            return Err(invalid("flash segment/page offset mismatch"));
        }
        let page_count = ((virtual_offset & 0xffff) + end - begin).div_ceil(0x10000);
        let first_virtual = virtual_offset & !0xffff;
        let first_file = begin & !0xffff;
        for page in 0..page_count {
            let dst = first_virtual + page * 0x10000;
            let src = first_file + page * 0x10000;
            if let Some(&(_, old)) = flash_pages.iter().find(|&&(existing, _)| existing == dst) {
                if old != src {
                    return Err(invalid("conflicting flash page mappings"));
                }
            } else {
                flash_pages.push((dst, src));
            }
        }
    }
    for (dst, src) in flash_pages {
        for i in 0..0x10000 {
            bus.flash[dst + i] = data.get(src + i).copied().unwrap_or(0xff);
        }
    }
    for (address, _, begin, end) in segments {
        for (index, byte) in data[begin..end].iter().enumerate() {
            bus.write_u8(address as u32 + index as u32, *byte);
        }
    }
    Ok(entry)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_scanout_pixels(bus: &Bus, pixels: &str) {
        let scanout = bus.scanout().expect("scanout frame is absent");
        for pixel in pixels.split(';') {
            let mut fields = pixel.split(',');
            let x = fields.next().unwrap().parse::<usize>().expect("pixel x");
            let y = fields.next().unwrap().parse::<usize>().expect("pixel y");
            let expected = u16::from_str_radix(fields.next().unwrap().trim_start_matches("0x"), 16)
                .expect("RGB565 pixel");
            assert!(
                fields.next().is_none() && x < 1280 && y < 720,
                "invalid pixel expectation"
            );
            let offset = ((1279 - x) * 720 + y) * 2;
            let actual = u16::from_le_bytes([scanout[offset], scanout[offset + 1]]);
            assert_eq!(actual, expected, "scanout pixel ({x}, {y})");
        }
    }

    fn image() -> Vec<u8> {
        let mut data = vec![0u8; 24];
        data[0] = 0xe9;
        data[1] = 1;
        data[4..8].copy_from_slice(&0x4ff0_0000u32.to_le_bytes());
        data[12..14].copy_from_slice(&18u16.to_le_bytes());
        data[23] = 1;
        data.extend_from_slice(&0x4ff0_0000u32.to_le_bytes());
        data.extend_from_slice(&4u32.to_le_bytes());
        data.extend_from_slice(&[1, 2, 3, 4]);
        let sum = 0xef ^ 1 ^ 2 ^ 3 ^ 4;
        while data.len() % 16 != 15 {
            data.push(0);
        }
        data.push(sum);
        let digest = Sha256::digest(&data);
        data.extend_from_slice(&digest);
        data
    }

    #[test]
    fn validates_before_writing_and_rejects_corruption() {
        let path = std::env::temp_dir().join(format!("nihos-esp-image-{}", std::process::id()));
        let mut image = image();
        std::fs::write(&path, &image).unwrap();
        let mut bus = Bus::new();
        assert_eq!(load(&mut bus, &path).unwrap(), 0x4ff0_0000);
        assert_eq!(&bus.sram[..4], &[1, 2, 3, 4]);
        bus.sram[0] = 99;
        image[32] ^= 1;
        std::fs::write(&path, &image).unwrap();
        assert_eq!(
            load(&mut bus, &path).unwrap_err().kind(),
            ErrorKind::InvalidData
        );
        assert_eq!(bus.sram[0], 99);
        let mut digest_corrupt = image.clone();
        digest_corrupt[32] ^= 1;
        *digest_corrupt.last_mut().unwrap() ^= 1;
        std::fs::write(&path, &digest_corrupt).unwrap();
        assert_eq!(
            load(&mut bus, &path).unwrap_err().kind(),
            ErrorKind::InvalidData
        );
        assert_eq!(bus.sram[0], 99);
        let mut unmapped = digest_corrupt;
        unmapped[24..28].copy_from_slice(&0x5000_0000u32.to_le_bytes());
        std::fs::write(&path, &unmapped).unwrap();
        assert_eq!(
            load(&mut bus, &path).unwrap_err().kind(),
            ErrorKind::InvalidData
        );
        assert_eq!(bus.sram[0], 99);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn flash_page_includes_header_and_rejects_misaligned_mapping() {
        let path = std::env::temp_dir().join(format!("nihos-esp-flash-{}", std::process::id()));
        let mut data = image();
        data[4..8].copy_from_slice(&0x4008_0020u32.to_le_bytes());
        data[24..28].copy_from_slice(&0x4008_0020u32.to_le_bytes());
        let digest_start = data.len() - 32;
        let digest = Sha256::digest(&data[..digest_start]);
        data[digest_start..].copy_from_slice(&digest);
        std::fs::write(&path, &data).unwrap();
        let mut bus = Bus::new();
        assert_eq!(load(&mut bus, &path).unwrap(), 0x4008_0020);
        assert_eq!(bus.read_u8(0x4008_0000), 0xe9);
        assert_eq!(bus.read_u32(0x4008_0020), 0x0403_0201);
        data[24..28].copy_from_slice(&0x4008_0021u32.to_le_bytes());
        data[4..8].copy_from_slice(&0x4008_0021u32.to_le_bytes());
        let digest = Sha256::digest(&data[..digest_start]);
        data[digest_start..].copy_from_slice(&digest);
        std::fs::write(&path, &data).unwrap();
        bus.flash[0x80000] = 0x77;
        assert!(load(&mut bus, &path).is_err());
        assert_eq!(bus.flash[0x80000], 0x77);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn rom_layout_load_is_read_only_and_rejects_invalid_boundary() {
        let path = std::env::temp_dir().join(format!("nihos-rom-layout-{}", std::process::id()));
        let mut elf = vec![0u8; 100];
        elf[..6].copy_from_slice(b"\x7fELF\x01\x01");
        elf[18..20].copy_from_slice(&243u16.to_le_bytes());
        elf[28..32].copy_from_slice(&52u32.to_le_bytes());
        elf[42..44].copy_from_slice(&32u16.to_le_bytes());
        elf[44..46].copy_from_slice(&1u16.to_le_bytes());
        elf[52..56].copy_from_slice(&1u32.to_le_bytes());
        elf[56..60].copy_from_slice(&84u32.to_le_bytes());
        elf[60..64].copy_from_slice(&0x4fc1_0000u32.to_le_bytes());
        elf[68..72].copy_from_slice(&16u32.to_le_bytes());
        elf[88..92].copy_from_slice(&0x4ff3_fba4u32.to_le_bytes());
        std::fs::write(&path, &elf).unwrap();
        let mut bus = Bus::new();
        load_rom_data(&mut bus, &path, 0x4fc1_0000).unwrap();
        assert_eq!(bus.read_u32(0x4fc1_fffc), 0x4fc1_0000);
        assert_eq!(bus.read_u32(0x4fc1_0004), 0x4ff3_fba4);
        bus.write_u32(0x4fc1_0004, 0);
        assert_eq!(bus.read_u32(0x4fc1_0004), 0x4ff3_fba4);
        elf[88..92].copy_from_slice(&0u32.to_le_bytes());
        std::fs::write(&path, &elf).unwrap();
        assert!(load_rom_data(&mut bus, &path, 0x4fc1_0000).is_err());
        assert_eq!(bus.read_u32(0x4fc1_0004), 0x4ff3_fba4);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    #[ignore = "requires NIHOS_EMU_ESP_APP"]
    fn inspect_external_app_execution() {
        let path = std::env::var("NIHOS_EMU_ESP_APP").expect("set NIHOS_EMU_ESP_APP");
        let mut bus = Bus::new();
        if std::env::var("NIHOS_EMU_TEST_ST7121").as_deref() == Ok("1") {
            bus.use_st7121_fixture();
        }
        if std::env::var("NIHOS_EMU_WASM_FLASH").as_deref() == Ok("1") {
            bus.rom_flash = Some(super::super::rom_flash::Flash::erased());
        }
        if std::env::var("NIHOS_EMU_BLANK_IME").as_deref() == Ok("1") {
            bus.rom_flash
                .as_mut()
                .expect("blank IME requires wasm flash fixture")
                .blank_dictionary = true;
        }
        if std::env::var("NIHOS_EMU_USB_EMPTY").as_deref() == Ok("1") {
            bus.usb_dwc = Some(super::super::usb_dwc::Usb::new());
        }
        let entry = load(&mut bus, path).unwrap();
        if let Ok(rom) = std::env::var("NIHOS_EMU_ROM_ELF") {
            let symbol =
                std::env::var("NIHOS_EMU_ROM_LAYOUT").expect("set ROM layout symbol address");
            let layout =
                u32::from_str_radix(symbol.trim_start_matches("0x"), 16).expect("hex ROM layout");
            load_rom_data(&mut bus, rom, layout).unwrap();
        }
        if std::env::var("NIHOS_EMU_EXEC_ROM").as_deref() == Ok("1") {
            assert!(
                !bus.rom_executable.is_empty(),
                "ROM execution requires executable ROM ELF"
            );
            bus.rom_execute = true;
        }
        if std::env::var("NIHOS_EMU_XTAL_40").as_deref() == Ok("1") {
            // Explicit bootloader-handoff approximation, not a reset value.
            bus.write_u32(0x5011_003c, 0x0028_0028);
        }
        if std::env::var("NIHOS_EMU_FLASH_CORE_80").as_deref() == Ok("1") {
            // IDF P4 bootloader_init_mspi_clock: SPLL 480 MHz divided by 6.
            // This seeds only the handoff register; it is not a bootloader run.
            let value = bus.read_u32(0x500e_6030);
            bus.write_u32(0x500e_6030, (value & !0xfff) | 0x5d);
        }
        let mut cpu = super::super::cpu::Cpu::new(entry);
        let break_pc = std::env::var("NIHOS_EMU_BREAK_PC")
            .ok()
            .map(|s| u32::from_str_radix(s.trim_start_matches("0x"), 16).expect("hex break PC"));
        let max_steps = std::env::var("NIHOS_EMU_MAX_STEPS")
            .ok()
            .map(|s| s.parse::<u64>().expect("integer step budget"))
            .unwrap_or(1_000_000);
        assert!(
            (1..=500_000_000).contains(&max_steps),
            "invalid step budget"
        );
        let input_after = std::env::var("NIHOS_EMU_INPUT_AFTER").ok();
        let input = std::env::var("NIHOS_EMU_INPUT").ok();
        assert_eq!(
            input_after.is_some(),
            input.is_some(),
            "input and trigger must be provided together"
        );
        let stop_on_log = std::env::var("NIHOS_EMU_STOP_ON_LOG").ok();
        let break_hits = std::env::var("NIHOS_EMU_BREAK_HITS")
            .ok()
            .map(|s| s.parse::<u32>().expect("integer breakpoint hit count"))
            .unwrap_or(1);
        assert!(
            (1..=1_000_000).contains(&break_hits),
            "invalid breakpoint hit count"
        );
        let checkpoint = std::env::var("NIHOS_EMU_CHECKPOINT_HITS")
            .ok()
            .map(|s| s.parse::<u32>().expect("integer checkpoint hit count"));
        let checkpoint_pixels = std::env::var("NIHOS_EMU_EXPECT_CHECKPOINT_PIXELS").ok();
        let checkpoint_input = std::env::var("NIHOS_EMU_CHECKPOINT_INPUT").ok();
        assert!(
            checkpoint_input.is_none() || checkpoint.is_some(),
            "checkpoint input requires a checkpoint"
        );
        assert_eq!(
            checkpoint.is_some(),
            checkpoint_pixels.is_some(),
            "checkpoint count and pixels must be supplied together"
        );
        if let Some(at) = checkpoint {
            assert!(
                break_pc.is_some() && (1..=break_hits).contains(&at),
                "invalid checkpoint"
            );
        }
        let mut hits = 0;
        let mut checkpoint_checked = false;
        let mut sent_input = false;
        let mut stopped_on_log = false;
        let mut checked_console_len = 0;
        for _ in 0..max_steps {
            if bus.console_output.len() != checked_console_len {
                checked_console_len = bus.console_output.len();
                if !sent_input
                    && let (Some(trigger), Some(input)) = (&input_after, &input)
                    && bus.console_output.ends_with(trigger.as_bytes())
                {
                    bus.keyboard_fifo.extend_from_slice(input.as_bytes());
                    sent_input = true;
                }
                if let Some(marker) = &stop_on_log
                    && bus.console_output.ends_with(marker.as_bytes())
                {
                    stopped_on_log = true;
                    break;
                }
            }
            if Some(cpu.pc) == break_pc {
                hits += 1;
                if Some(hits) == checkpoint {
                    assert_scanout_pixels(&bus, checkpoint_pixels.as_deref().unwrap());
                    checkpoint_checked = true;
                    println!("scanout checkpoint passed at breakpoint hit {hits}");
                    if let Some(input) = &checkpoint_input {
                        bus.keyboard_fifo.extend_from_slice(input.as_bytes());
                    }
                }
            }
            if Some(cpu.pc) == break_pc && hits == break_hits {
                println!(
                    "break pc={:#010x} ra={:#010x} sp={:#010x} mepc={:#010x} mcause={:#010x} a0..a3={:08x?}",
                    cpu.pc,
                    cpu.x[1],
                    cpu.x[2],
                    cpu.mepc,
                    cpu.mcause,
                    &cpu.x[10..14]
                );
                if cpu.pc == 0x4006_359e && (0x4ff0_0000..=0x4fff_ffc0).contains(&cpu.x[10]) {
                    let words: Vec<_> = (0..14).map(|i| bus.read_u32(cpu.x[10] + i * 4)).collect();
                    println!("flash HAL config={words:08x?}");
                    if let Ok(expected) = std::env::var("NIHOS_EMU_EXPECT_FLASH_CLK") {
                        assert_eq!(
                            words[12],
                            expected.parse::<u32>().expect("integer clock MHz")
                        );
                    }
                }
                for index in [10, 12, 13] {
                    let addr = cpu.x[index];
                    if (0x4000_0000..0x40ff_ff00).contains(&addr)
                        || (0x4ff0_0000..0x4fff_ff00).contains(&addr)
                    {
                        let bytes: Vec<_> = (0..200)
                            .map(|i| bus.read_u8(addr + i))
                            .take_while(|&c| c != 0)
                            .collect();
                        println!("a{} text={:?}", index - 10, String::from_utf8_lossy(&bytes));
                        if index == 10
                            && let Ok(expected) = std::env::var("NIHOS_EMU_EXPECT_BREAK_TEXT")
                        {
                            assert!(String::from_utf8_lossy(&bytes).contains(&expected));
                        }
                    }
                }
                break;
            }
            if !cpu.step(&mut bus) {
                break;
            }
        }
        println!(
            "direct app entry={entry:#010x} steps={} pc={:#010x} fault={:?}",
            cpu.instructions_executed, cpu.pc, cpu.fault
        );
        println!("modeled display DMA frames={}", bus.scanout_frames);
        let nonzero_pixels = bus
            .scanout()
            .map(|frame| frame.iter().filter(|&&byte| byte != 0).count());
        println!("modeled display nonzero bytes={nonzero_pixels:?}");
        if let Ok(path) = std::env::var("NIHOS_EMU_DUMP_SCANOUT") {
            std::fs::write(path, bus.scanout().expect("scanout frame is absent"))
                .expect("write raw scanout");
        }
        if let Ok(expected) = std::env::var("NIHOS_EMU_EXPECT_SCANOUT_NONZERO") {
            assert_eq!(
                nonzero_pixels,
                Some(
                    expected
                        .parse::<usize>()
                        .expect("integer nonzero-byte count")
                )
            );
        }
        if let Ok(minimum) = std::env::var("NIHOS_EMU_EXPECT_SCANOUT_FRAMES_MIN") {
            assert!(bus.scanout_frames >= minimum.parse::<u64>().expect("integer frame count"));
        }
        if let Ok(minimum) = std::env::var("NIHOS_EMU_EXPECT_SCANOUT_NONZERO_MIN") {
            assert!(nonzero_pixels.is_some_and(|count| {
                count
                    >= minimum
                        .parse::<usize>()
                        .expect("integer nonzero-byte count")
            }));
        }
        if let Ok(pixels) = std::env::var("NIHOS_EMU_EXPECT_SCANOUT_PIXELS") {
            assert_scanout_pixels(&bus, &pixels);
        }
        if std::env::var("NIHOS_EMU_DUMP_DISPLAY").as_deref() == Ok("1") {
            let mut regs: Vec<_> = bus
                .mmio
                .iter()
                .filter(|(address, _)| {
                    (0x5008_1000..0x5008_1800).contains(*address)
                        || (0x500a_0000..0x500a_1000).contains(*address)
                })
                .map(|(&address, &value)| (address, value))
                .collect();
            regs.sort_by_key(|(address, _)| *address);
            println!("display registers: {regs:08x?}");
            let route = bus.mmio.get(&(0x500d_6000 + 24 * 4)).copied();
            println!(
                "display IRQ route={route:?} mstatus={:#010x} mie={:#010x} mtvec={:#010x} mtvt={:#010x}",
                cpu.mstatus, cpu.mie, cpu.mtvec, cpu.mtvt
            );
            if let Some(line) = route.filter(|line| *line < 64) {
                println!(
                    "display CLIC line {line}: {:#010x}",
                    bus.read_u32(0x2080_1000 + line * 4)
                );
            }
            let descriptor = bus.mmio.get(&0x5008_1128).copied().unwrap_or(0) & !63;
            if (0x4ff0_0000..=0x4fff_ffc0).contains(&descriptor) {
                let words: Vec<_> = (0..16).map(|i| bus.read_u32(descriptor + i * 4)).collect();
                println!("display descriptor at {descriptor:#010x}: {words:08x?}");
            }
        }
        if let Ok(expected) = std::env::var("NIHOS_EMU_EXPECT_SCANOUT_FRAMES") {
            assert_eq!(
                bus.scanout_frames,
                expected.parse::<u64>().expect("integer frame count")
            );
        }
        if let Some(flash) = &bus.rom_flash {
            println!(
                "volatile flash reads={} programs={} erases={}",
                flash.reads, flash.programs, flash.erases
            );
            if let Ok(minimum) = std::env::var("NIHOS_EMU_EXPECT_FLASH_PROGRAMS_MIN") {
                assert!(flash.programs >= minimum.parse().expect("integer program count"));
            }
        }
        let mut spi: Vec<_> = bus
            .mmio
            .iter()
            .filter(|(address, _)| (0x5008_d000..0x5008_d100).contains(*address))
            .collect();
        spi.sort_by_key(|(address, _)| *address);
        println!("SPI1 registers: {spi:08x?}");
        if cpu.pc == 0x4fc0_0108 && (0x4ff0_0000..0x4fff_ffd0).contains(&cpu.x[11]) {
            let words: Vec<_> = (0..8).map(|i| bus.read_u32(cpu.x[11] + 4 * i)).collect();
            println!("SPI ROM config words={words:08x?}");
        }
        println!(
            "guest console: {:?}",
            String::from_utf8_lossy(&bus.console_output)
        );
        println!(
            "registers a0..a7={:08x?} sp={:#010x} ra={:#010x}",
            &cpu.x[10..18],
            cpu.x[2],
            cpu.x[1]
        );
        if cpu.pc == 0x4fc0_0390 && (0x4ff0_0000..=0x4fff_ffb0).contains(&cpu.x[11]) {
            let words: Vec<_> = (0..20).map(|i| bus.read_u32(cpu.x[11] + 4 * i)).collect();
            println!("newlib FILE words={words:08x?}");
            println!(
                "ROM syscall table pointer={:#010x}",
                bus.read_u32(0x4ff3_ffe4)
            );
        }
        if cpu.pc == 0x4fc0_0024
            && ((0x4000_0000..0x4100_0000).contains(&cpu.x[10])
                || (0x4ff0_0000..0x5000_0000).contains(&cpu.x[10]))
        {
            let bytes: Vec<_> = (0..160)
                .map(|i| bus.read_u8(cpu.x[10] + i))
                .take_while(|&c| c != 0)
                .collect();
            println!("ROM format: {:?}", String::from_utf8_lossy(&bytes));
        }
        // An unsupported instruction is an observed boundary, not boot success.
        assert!(cpu.instructions_executed > 0);
        if input.is_some() {
            assert!(sent_input, "console input trigger not observed");
        }
        if break_hits > 1 {
            assert!(hits >= break_hits, "breakpoint hit count not reached");
        }
        if checkpoint.is_some() {
            assert!(checkpoint_checked, "scanout checkpoint not reached");
        }
        if stop_on_log.is_some() {
            assert!(stopped_on_log, "console stop marker not observed");
        }
        if std::env::var("NIHOS_EMU_EXPECT_BUDGET").as_deref() == Ok("1") {
            assert_eq!(
                cpu.instructions_executed, max_steps,
                "probe stopped before budget"
            );
            assert!(cpu.fault.is_none(), "probe faulted: {:?}", cpu.fault);
        }
        if let Ok(expected) = std::env::var("NIHOS_EMU_EXPECT_STOP") {
            assert!(
                cpu.fault
                    .as_deref()
                    .is_some_and(|fault| fault.contains(&expected)),
                "expected stop {expected:?}, got {:?}",
                cpu.fault
            );
        }
        if let Ok(expected) = std::env::var("NIHOS_EMU_EXPECT_PC") {
            let expected = u32::from_str_radix(expected.trim_start_matches("0x"), 16)
                .expect("hex expected PC");
            assert_eq!(cpu.pc, expected);
        }
        if let Ok(expected) = std::env::var("NIHOS_EMU_EXPECT_LOG") {
            assert!(String::from_utf8_lossy(&bus.console_output).contains(&expected));
        }
        if let Ok(forbidden) = std::env::var("NIHOS_EMU_FORBID_LOG") {
            assert!(!String::from_utf8_lossy(&bus.console_output).contains(&forbidden));
        }
    }
}
