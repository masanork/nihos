//! Experimental, volatile physical NOR window for MeOS's wasmapps partition.
//! This is independent of the direct loader's virtual flash page view.
use super::bus::Bus;

const BASE: u32 = 0x00a0_0000;
const SIZE: usize = 0x0020_0000;
const SECTOR: usize = 4096;

pub struct Flash {
    bytes: Vec<u8>,
    unlocked: bool,
    pub blank_dictionary: bool,
    pub reads: u64,
    pub programs: u64,
    pub erases: u64,
}

impl Flash {
    pub fn erased() -> Self {
        Self {
            bytes: vec![0xff; SIZE],
            unlocked: false,
            blank_dictionary: false,
            reads: 0,
            programs: 0,
            erases: 0,
        }
    }
}

fn range(address: u32, len: usize) -> Result<std::ops::Range<usize>, String> {
    let start = address.checked_sub(BASE).ok_or("outside fixture flash")? as usize;
    let end = start
        .checked_add(len)
        .filter(|&end| end <= SIZE)
        .ok_or("outside fixture flash")?;
    Ok(start..end)
}

fn ram(bus: &Bus, address: u32, len: usize) -> bool {
    let start = u64::from(address);
    let end = start + len as u64;
    address & 3 == 0
        && bus.mapped_backing_range(address, len as u64)
        && [
            (0x3010_0000, 0x3010_2000),
            (0x4800_0000, 0x4a00_0000),
            (0x4ff0_0000, 0x5000_0000),
            (0x5010_8000, 0x5011_0000),
        ]
        .iter()
        .any(|&(lo, hi)| start >= lo && end <= hi && !(bus.cache_l2_suspended && lo == 0x4800_0000))
}

pub fn call(bus: &mut Bus, pc: u32, first: u32, second: u32, third: u32) -> Result<(), String> {
    if bus.rom_flash.is_none() {
        return Err("fixture disabled".into());
    }
    if pc == 0x4fc0_015c {
        bus.rom_flash.as_mut().unwrap().unlocked = true;
        return Ok(());
    }
    if !bus.rom_flash.as_ref().unwrap().unlocked {
        return Err("flash is locked".into());
    }
    if pc == 0x4fc0_014c {
        let address = first.checked_mul(SECTOR as u32).ok_or("sector overflow")?;
        let r = range(address, SECTOR)?;
        let flash = bus.rom_flash.as_mut().unwrap();
        flash.bytes[r].fill(0xff);
        flash.erases += 1;
        return Ok(());
    }
    let source_is_flash = pc == 0x4fc0_0154
        && second & 3 == 0
        && !bus.cache_l2_suspended
        && second >= 0x4000_0000
        && u64::from(second) + u64::from(third) <= 0x4100_0000;
    if !matches!(pc, 0x4fc0_0154 | 0x4fc0_0158)
        || first & 3 != 0
        || third & 3 != 0
        || third > 65536
        || !(ram(bus, second, third as usize) || source_is_flash)
    {
        return Err("invalid flash transfer".into());
    }
    let blank_dictionary = pc == 0x4fc0_0158
        && bus.rom_flash.as_ref().unwrap().blank_dictionary
        && first >= 0x0040_0000
        && u64::from(first) + u64::from(third) <= u64::from(BASE);
    if blank_dictionary {
        for offset in 0..third {
            bus.write_u8(second + offset, 0xff);
        }
        bus.rom_flash.as_mut().unwrap().reads += 1;
        return Ok(());
    }
    let r = range(first, third as usize)?;
    if pc == 0x4fc0_0154 {
        let source: Vec<_> = (0..third).map(|i| bus.read_u8(second + i)).collect();
        for (old, new) in bus.rom_flash.as_mut().unwrap().bytes[r]
            .iter_mut()
            .zip(source)
        {
            *old &= new;
        }
        bus.rom_flash.as_mut().unwrap().programs += 1;
    } else {
        let source = bus.rom_flash.as_ref().unwrap().bytes[r].to_vec();
        for (i, byte) in source.into_iter().enumerate() {
            bus.write_u8(second + i as u32, byte);
        }
        bus.rom_flash.as_mut().unwrap().reads += 1;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_nor_transfers_are_isolated_and_require_unlock() {
        let mut bus = Bus::new();
        bus.rom_flash = Some(Flash::erased());
        let ram = 0x4ff0_0100;
        bus.write_u32(ram, 0x1234_5678);
        assert!(call(&mut bus, 0x4fc0_0154, BASE, ram, 4).is_err());
        call(&mut bus, 0x4fc0_015c, 0, 0, 0).unwrap();
        call(&mut bus, 0x4fc0_0154, BASE, ram, 4).unwrap();
        bus.write_u32(ram, 0xffff_0000);
        call(&mut bus, 0x4fc0_0154, BASE, ram, 4).unwrap();
        call(&mut bus, 0x4fc0_0158, BASE, ram, 4).unwrap();
        assert_eq!(bus.read_u32(ram), 0x1234_0000);
        assert!(call(&mut bus, 0x4fc0_014c, 0, 0, 0).is_err());
        assert!(call(&mut bus, 0x4fc0_0158, BASE + SIZE as u32 - 2, ram, 4).is_err());
        assert!(call(&mut bus, 0x4fc0_0158, BASE, 0x5000_0000, 4).is_err());
        bus.write_u32(0x5008_e380, 1);
        bus.write_u32(0x5008_e37c, 0);
        bus.write_u32(0x4800_fffc, 0x7654_3210);
        let programs = bus.rom_flash.as_ref().unwrap().programs;
        assert!(call(&mut bus, 0x4fc0_0154, BASE, 0x4800_fffc, 8).is_err());
        assert_eq!(bus.rom_flash.as_ref().unwrap().programs, programs);
        assert_eq!(bus.read_u32(0x4800_fffc), 0x7654_3210);
        assert!(call(&mut bus, 0x4fc0_0158, BASE, 0x4800_fffc, 8).is_err());
        assert_eq!(bus.read_u32(0x4800_fffc), 0x7654_3210);
        assert!(call(&mut bus, 0x4fc0_0158, 0x0040_0000, ram, 4).is_err());
        bus.rom_flash.as_mut().unwrap().blank_dictionary = true;
        call(&mut bus, 0x4fc0_0158, 0x0040_0000, ram, 4).unwrap();
        assert_eq!(bus.read_u32(ram), u32::MAX);
        assert!(call(&mut bus, 0x4fc0_0154, 0x0040_0000, ram, 4).is_err());
        assert!(call(&mut bus, 0x4fc0_014c, 0x0040_0000 / SECTOR as u32, 0, 0).is_err());
        call(&mut bus, 0x4fc0_014c, BASE / SECTOR as u32, 0, 0).unwrap();
        call(&mut bus, 0x4fc0_0158, BASE, ram, 4).unwrap();
        assert_eq!(bus.read_u32(ram), u32::MAX);
        bus.flash[..4].copy_from_slice(&[1, 2, 3, 4]);
        call(&mut bus, 0x4fc0_0154, BASE, 0x4000_0000, 4).unwrap();
        call(&mut bus, 0x4fc0_0158, BASE, ram, 4).unwrap();
        assert_eq!(bus.read_u32(ram), 0x0403_0201);
        call(&mut bus, 0x4fc0_014c, BASE / SECTOR as u32, 0, 0).unwrap();
        assert_eq!(&bus.flash[..4], &[1, 2, 3, 4]); // separate virtual mapping
    }
}
