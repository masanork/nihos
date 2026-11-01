//! 32-bit RISC-V ELF loader for nihos firmware.

use super::bus::{Bus, FLASH_BASE, FLASH_SIZE, SRAM_BASE, SRAM_SIZE};
use std::fs::File;
use std::io::{Read, Result};
use std::path::Path;

pub struct ElfLoader;

impl ElfLoader {
    pub fn load_elf(bus: &mut Bus, path: impl AsRef<Path>) -> Result<u32> {
        let mut file = File::open(path)?;
        let mut data = Vec::new();
        file.read_to_end(&mut data)?;

        if data.len() < 52 || &data[0..4] != b"\x7fELF" {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Invalid ELF header",
            ));
        }

        // 32-bit Little Endian check
        if data[4] != 1 || data[5] != 1 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Not 32-bit Little Endian ELF",
            ));
        }

        if u16::from_le_bytes(data[16..18].try_into().unwrap()) != 2
            || u16::from_le_bytes(data[18..20].try_into().unwrap()) != 243
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "expected a RISC-V executable ELF",
            ));
        }
        let e_entry = u32::from_le_bytes(data[24..28].try_into().unwrap());
        let e_phoff = u32::from_le_bytes(data[28..32].try_into().unwrap()) as usize;
        let e_phentsize = u16::from_le_bytes(data[42..44].try_into().unwrap()) as usize;
        let e_phnum = u16::from_le_bytes(data[44..46].try_into().unwrap()) as usize;

        if e_phentsize < 32 || e_phnum == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "invalid ELF program header table",
            ));
        }

        // Direct virtual loading cannot represent ESP-IDF images whose LOAD
        // segments alias the same virtual flash window with different mappings.
        // Reject them rather than silently overwriting executable bytes.
        let mut loaded_ranges: Vec<(u64, u64)> = Vec::new();
        for i in 0..e_phnum {
            let off = e_phoff
                .checked_add(i.checked_mul(e_phentsize).ok_or_else(|| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, "ELF header overflow")
                })?)
                .ok_or_else(|| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, "ELF header overflow")
                })?;
            if off.checked_add(32).is_none_or(|end| end > data.len()) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Truncated ELF program headers",
                ));
            }
            let kind = u32::from_le_bytes(data[off..off + 4].try_into().unwrap());
            let offset = u32::from_le_bytes(data[off + 4..off + 8].try_into().unwrap()) as u64;
            let start = u32::from_le_bytes(data[off + 8..off + 12].try_into().unwrap()) as u64;
            let file_size = u32::from_le_bytes(data[off + 16..off + 20].try_into().unwrap()) as u64;
            let memory_size =
                u32::from_le_bytes(data[off + 20..off + 24].try_into().unwrap()) as u64;
            if kind == 1 && memory_size != 0 {
                let end = start + memory_size;
                let in_flash =
                    start >= FLASH_BASE as u64 && end <= FLASH_BASE as u64 + FLASH_SIZE as u64;
                let in_sram =
                    start >= SRAM_BASE as u64 && end <= SRAM_BASE as u64 + SRAM_SIZE as u64;
                if file_size > memory_size || offset + file_size > data.len() as u64 {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "truncated ELF LOAD segment",
                    ));
                }
                if (!in_flash && !in_sram)
                    || loaded_ranges.iter().any(|&(a, b)| start < b && a < end)
                {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::Unsupported,
                        "unmapped or overlapping ELF LOAD segments require a flash MMU/bootloader",
                    ));
                }
                loaded_ranges.push((start, end));
            }
        }
        for i in 0..e_phnum {
            let off = e_phoff + i * e_phentsize;
            if off + 32 > data.len() {
                break;
            }
            let p_type = u32::from_le_bytes(data[off..off + 4].try_into().unwrap());
            let p_offset = u32::from_le_bytes(data[off + 4..off + 8].try_into().unwrap()) as usize;
            let p_vaddr = u32::from_le_bytes(data[off + 8..off + 12].try_into().unwrap());
            let p_filesz =
                u32::from_le_bytes(data[off + 16..off + 20].try_into().unwrap()) as usize;
            let p_memsz = u32::from_le_bytes(data[off + 20..off + 24].try_into().unwrap()) as usize;

            // PT_LOAD = 1
            if p_type == 1 && p_memsz > 0 {
                // Copy filesz bytes to p_vaddr
                if p_filesz > 0 && p_offset + p_filesz <= data.len() {
                    for b in 0..p_filesz {
                        bus.write_u8(p_vaddr.wrapping_add(b as u32), data[p_offset + b]);
                    }
                }
                // Zero out remaining memsz - filesz (BSS)
                if p_memsz > p_filesz {
                    for b in p_filesz..p_memsz {
                        bus.write_u8(p_vaddr.wrapping_add(b as u32), 0);
                    }
                }
            }
        }

        Ok(e_entry)
    }

    /// Load the standalone Japanese dictionary blob into the flash partition area.
    pub fn load_dictionary(
        bus: &mut Bus,
        path: impl AsRef<Path>,
        flash_offset: u32,
    ) -> Result<usize> {
        let mut file = File::open(path)?;
        let mut data = Vec::new();
        file.read_to_end(&mut data)?;

        if (flash_offset as usize)
            .checked_add(data.len())
            .is_none_or(|end| end > FLASH_SIZE)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "dictionary exceeds flash capacity",
            ));
        }
        let dest = FLASH_BASE + flash_offset;
        for (i, &b) in data.iter().enumerate() {
            bus.write_u8(dest.wrapping_add(i as u32), b);
        }

        Ok(data.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_truncated_load_without_mutating_bus() {
        let mut image = vec![0u8; 84];
        image[..6].copy_from_slice(b"\x7fELF\x01\x01");
        image[16..18].copy_from_slice(&2u16.to_le_bytes());
        image[18..20].copy_from_slice(&243u16.to_le_bytes());
        image[28..32].copy_from_slice(&52u32.to_le_bytes());
        image[42..44].copy_from_slice(&32u16.to_le_bytes());
        image[44..46].copy_from_slice(&1u16.to_le_bytes());
        image[52..56].copy_from_slice(&1u32.to_le_bytes());
        image[56..60].copy_from_slice(&84u32.to_le_bytes());
        image[60..64].copy_from_slice(&SRAM_BASE.to_le_bytes());
        image[68..72].copy_from_slice(&4u32.to_le_bytes());
        image[72..76].copy_from_slice(&4u32.to_le_bytes());
        let path = std::env::temp_dir().join(format!("nihos-invalid-elf-{}", std::process::id()));
        std::fs::write(&path, image).unwrap();
        let mut bus = Bus::new();
        let error = ElfLoader::load_elf(&mut bus, &path).unwrap_err();
        std::fs::remove_file(path).unwrap();
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(bus.sram[0], 0);
    }
}
