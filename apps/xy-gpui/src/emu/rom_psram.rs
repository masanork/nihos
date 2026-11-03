//! Small, explicitly bounded model of P4 ROM PSRAM command setup.
use super::bus::Bus;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Command {
    pub opcode: u16,
    pub address: u32,
    pub tx: u32,
    pub tx_bits: u32,
    pub rx: u32,
    pub rx_bits: u32,
    pub dummy_bits: u32,
}

fn ram(address: u32, size: u32) -> bool {
    let start = u64::from(address);
    let end = start + u64::from(size);
    [
        (0x3010_0000, 0x3010_2000),
        (0x4800_0000, 0x4a00_0000),
        (0x4ff0_0000, 0x5000_0000),
        (0x5010_8000, 0x5011_0000),
    ]
    .iter()
    .any(|&(a, b)| start >= a && end <= b)
}

pub fn configure(bus: &mut Bus, controller: u32, pointer: u32) -> Result<(), String> {
    bus.rom_psram_command = None;
    if controller != 3
        || bus.rom_spi_mode != Some((3, 7))
        || pointer & 3 != 0
        || !ram(pointer, 32)
        || !bus.mapped_backing_range(pointer, 32)
    {
        return Err("invalid PSRAM SPI controller, mode, or command pointer".into());
    }
    let first = bus.read_u32(pointer);
    let opcode = first as u16;
    let command_bits = first >> 16;
    let addr_ptr = bus.read_u32(pointer + 4);
    let addr_bits = bus.read_u32(pointer + 8);
    let tx = bus.read_u32(pointer + 12);
    let tx_bits = bus.read_u32(pointer + 16);
    let rx = bus.read_u32(pointer + 20);
    let rx_bits = bus.read_u32(pointer + 24);
    let dummy_bits = bus.read_u32(pointer + 28);
    if command_bits != 16
        || addr_bits != 32
        || addr_ptr & 3 != 0
        || !ram(addr_ptr, 4)
        || !bus.mapped_backing_range(addr_ptr, 4)
    {
        return Err("invalid PSRAM SPI command/address width or pointer".into());
    }
    let address = bus.read_u32(addr_ptr);
    let read_ok = opcode == 0x4040
        && tx_bits == 0
        && tx == 0
        && matches!(rx_bits, 8 | 16)
        && ram(rx, rx_bits / 8)
        && bus.mapped_backing_range(rx, u64::from(rx_bits / 8))
        && dummy_bits == 12;
    let write_ok = opcode == 0xc0c0
        && tx_bits == 16
        && ram(tx, 2)
        && bus.mapped_backing_range(tx, 2)
        && rx == 0
        && rx_bits == 0
        && dummy_bits == 0;
    let memory_read = opcode == 0
        && tx == 0
        && tx_bits == 0
        && (8..=512).contains(&rx_bits)
        && rx_bits.is_multiple_of(8)
        && ram(rx, rx_bits / 8)
        && bus.mapped_backing_range(rx, u64::from(rx_bits / 8))
        && dummy_bits == 26
        && u64::from(address) + u64::from(rx_bits / 8) <= bus.psram.len() as u64;
    let memory_write = opcode == 0x8080
        && (8..=512).contains(&tx_bits)
        && tx_bits.is_multiple_of(8)
        && ram(tx, tx_bits / 8)
        && bus.mapped_backing_range(tx, u64::from(tx_bits / 8))
        && rx == 0
        && rx_bits == 0
        && dummy_bits == 12
        && u64::from(address) + u64::from(tx_bits / 8) <= bus.psram.len() as u64;
    if !((read_ok || write_ok) && matches!(address, 0 | 2 | 4 | 8) || memory_read || memory_write) {
        return Err(format!(
            "unsupported PSRAM SPI command opcode={opcode:#06x} address={address:#x} tx_bits={tx_bits} rx_bits={rx_bits} dummy={dummy_bits}"
        ));
    }
    bus.rom_psram_command = Some(Command {
        opcode,
        address,
        tx,
        tx_bits,
        rx,
        rx_bits,
        dummy_bits,
    });
    Ok(())
}

pub fn start(
    bus: &mut Bus,
    controller: u32,
    rx: u32,
    rx_len: u32,
    cs: u32,
    write: u32,
) -> Result<(), String> {
    let cmd = bus
        .rom_psram_command
        .take()
        .ok_or("PSRAM SPI command not configured")?;
    if controller != 3
        || bus.rom_spi_mode != Some((3, 7))
        || rx != cmd.rx
        || rx_len != cmd.rx_bits / 8
        || cs != 2
        || write != 0
        || (rx_len != 0 && (!ram(rx, rx_len) || !bus.mapped_backing_range(rx, u64::from(rx_len))))
        || (cmd.tx_bits != 0 && !bus.mapped_backing_range(cmd.tx, u64::from(cmd.tx_bits / 8)))
    {
        return Err("invalid PSRAM SPI start arguments".into());
    }
    if cmd.opcode == 0xc0c0 {
        let value = u32::from(bus.read_u16(cmd.tx));
        bus.mmio.insert(0x5008_ff00 | cmd.address, value);
        return Ok(());
    }
    if cmd.opcode == 0x8080 {
        let mut data = [0u8; 64];
        let len = (cmd.tx_bits / 8) as usize;
        for (index, byte) in data[..len].iter_mut().enumerate() {
            *byte = bus.read_u8(cmd.tx + index as u32);
        }
        let start = cmd.address as usize;
        bus.psram[start..start + len].copy_from_slice(&data[..len]);
        return Ok(());
    }
    if cmd.opcode == 0 {
        let start = cmd.address as usize;
        let mut data = [0u8; 64];
        data[..rx_len as usize].copy_from_slice(&bus.psram[start..start + rx_len as usize]);
        for (i, byte) in data[..rx_len as usize].iter().enumerate() {
            bus.write_u8(rx + i as u32, *byte);
        }
        return Ok(());
    }
    let default = match cmd.address {
        0 => 0x0d24,
        2 => 0x00c7,
        4 => 0x0040,
        8 => 0x004b,
        _ => return Err("unsupported PSRAM mode register".into()),
    };
    let value = bus
        .mmio
        .get(&(0x5008_ff00 | cmd.address))
        .copied()
        .unwrap_or(default);
    bus.write_u8(rx, value as u8);
    if rx_len == 2 {
        bus.write_u8(rx + 1, (value >> 8) as u8);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_unmapped_buffers_and_mapping_changes_before_transfer() {
        let mut bus = Bus::new();
        let ptr = 0x4ff0_0100;
        let addr_ptr = 0x4ff0_0200;
        let edge = 0x4800_fffe;
        bus.rom_spi_mode = Some((3, 7));
        bus.write_u32(addr_ptr, 128);
        bus.write_u8(edge, 0x12);
        bus.write_u8(edge + 1, 0x34);
        bus.psram[128..132].copy_from_slice(&[0xaa; 4]);
        for (i, value) in [0x0010_8080, addr_ptr, 32, edge, 32, 0, 0, 12]
            .iter()
            .enumerate()
        {
            bus.write_u32(ptr + i as u32 * 4, *value);
        }
        configure(&mut bus, 3, ptr).unwrap();
        bus.write_u32(0x5008_e380, 1);
        bus.write_u32(0x5008_e37c, 0);
        assert!(start(&mut bus, 3, 0, 0, 2, 0).is_err());
        assert_eq!(&bus.psram[128..132], &[0xaa; 4]);
        assert!(bus.rom_psram_command.is_none());
        assert!(configure(&mut bus, 3, ptr).is_err());

        bus.write_u32(0x5008_e37c, 0xc01);
        for (i, value) in [0x0010_0000, addr_ptr, 32, 0, 0, edge, 32, 26]
            .iter()
            .enumerate()
        {
            bus.write_u32(ptr + i as u32 * 4, *value);
        }
        configure(&mut bus, 3, ptr).unwrap();
        bus.write_u32(0x5008_e37c, 0);
        assert!(start(&mut bus, 3, edge, 4, 2, 0).is_err());
        assert_eq!(bus.read_u8(edge), 0x12);
        assert_eq!(bus.read_u8(edge + 1), 0x34);
        assert!(bus.fault.is_none());
    }
    #[test]
    fn register_read_checks_state_and_destination() {
        let mut bus = Bus::new();
        let ptr = 0x4ff0_0100;
        let addr_ptr = 0x4ff0_0200;
        let dst = 0x4ff0_0300;
        bus.rom_spi_mode = Some((3, 7));
        for (offset, value) in [0x0010_4040, addr_ptr, 32, 0, 0, dst, 16, 12]
            .iter()
            .enumerate()
        {
            bus.write_u32(ptr + (offset as u32) * 4, *value);
        }
        bus.write_u32(addr_ptr, 2);
        configure(&mut bus, 3, ptr).unwrap();
        assert!(start(&mut bus, 3, dst + 1, 2, 2, 0).is_err());
        assert_eq!(bus.read_u16(dst), 0);
        assert!(start(&mut bus, 3, dst, 2, 2, 0).is_err());
        configure(&mut bus, 3, ptr).unwrap();
        start(&mut bus, 3, dst, 2, 2, 0).unwrap();
        assert_eq!(bus.read_u16(dst), 0x00c7);
        assert!(start(&mut bus, 3, dst, 2, 2, 0).is_err());
        bus.write_u32(ptr + 20, 0x5000_0000);
        assert!(configure(&mut bus, 3, ptr).is_err());
        assert!(bus.rom_psram_command.is_none());
    }

    #[test]
    fn register_write_is_visible_to_reads_and_invalid_write_does_nothing() {
        let mut bus = Bus::new();
        let ptr = 0x4ff0_0100;
        let addr_ptr = 0x4ff0_0200;
        let tx = 0x4ff0_0300;
        let rx = 0x4ff0_0400;
        bus.rom_spi_mode = Some((3, 7));
        bus.write_u32(addr_ptr, 8);
        bus.write_u16(tx, 0xabcd);
        for (offset, value) in [0x0010_c0c0, addr_ptr, 32, tx, 16, 0, 0, 0]
            .iter()
            .enumerate()
        {
            bus.write_u32(ptr + offset as u32 * 4, *value);
        }
        configure(&mut bus, 3, ptr).unwrap();
        assert!(start(&mut bus, 3, 0, 0, 1, 0).is_err());
        assert!(!bus.mmio.contains_key(&0x5008_ff08));
        configure(&mut bus, 3, ptr).unwrap();
        start(&mut bus, 3, 0, 0, 2, 0).unwrap();
        for (offset, value) in [0x0010_4040, addr_ptr, 32, 0, 0, rx, 8, 12]
            .iter()
            .enumerate()
        {
            bus.write_u32(ptr + offset as u32 * 4, *value);
        }
        configure(&mut bus, 3, ptr).unwrap();
        start(&mut bus, 3, rx, 1, 2, 0).unwrap();
        assert_eq!(bus.read_u8(rx), 0xcd);
        assert_eq!(bus.read_u8(rx + 1), 0);
    }

    #[test]
    fn data_transaction_shares_psram_and_rejects_out_of_range() {
        let mut bus = Bus::new();
        let ptr = 0x4ff0_0100;
        let addr_ptr = 0x4ff0_0200;
        let tx = 0x4ff0_0300;
        let rx = 0x4ff0_0400;
        bus.rom_spi_mode = Some((3, 7));
        bus.write_u32(addr_ptr, 128);
        bus.write_u32(tx, 0x5a6b_7c8d);
        for (i, value) in [0x0010_8080, addr_ptr, 32, tx, 32, 0, 0, 12]
            .iter()
            .enumerate()
        {
            bus.write_u32(ptr + i as u32 * 4, *value);
        }
        configure(&mut bus, 3, ptr).unwrap();
        start(&mut bus, 3, 0, 0, 2, 0).unwrap();
        assert_eq!(bus.read_u32(0x4800_0080), 0x5a6b_7c8d);
        for (i, value) in [0x0010_0000, addr_ptr, 32, 0, 0, rx, 32, 26]
            .iter()
            .enumerate()
        {
            bus.write_u32(ptr + i as u32 * 4, *value);
        }
        configure(&mut bus, 3, ptr).unwrap();
        start(&mut bus, 3, rx, 4, 2, 0).unwrap();
        assert_eq!(bus.read_u32(rx), 0x5a6b_7c8d);
        for i in 0..64u32 {
            bus.write_u8(tx + i, i as u8);
        }
        for (i, value) in [0x0010_8080, addr_ptr, 32, tx, 512, 0, 0, 12]
            .iter()
            .enumerate()
        {
            bus.write_u32(ptr + i as u32 * 4, *value);
        }
        configure(&mut bus, 3, ptr).unwrap();
        start(&mut bus, 3, 0, 0, 2, 0).unwrap();
        for (i, value) in [0x0010_0000, addr_ptr, 32, 0, 0, rx, 512, 26]
            .iter()
            .enumerate()
        {
            bus.write_u32(ptr + i as u32 * 4, *value);
        }
        configure(&mut bus, 3, ptr).unwrap();
        start(&mut bus, 3, rx, 64, 2, 0).unwrap();
        for i in 0..64u32 {
            assert_eq!(bus.read_u8(rx + i), i as u8);
        }
        bus.write_u32(addr_ptr, 32 * 1024 * 1024 - 3);
        assert!(configure(&mut bus, 3, ptr).is_err());
    }
}
