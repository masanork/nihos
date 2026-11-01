//! 32-bit RISC-V ELF loader for nihos firmware.

use super::bus::{Bus, FLASH_BASE};
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

        let e_entry = u32::from_le_bytes(data[24..28].try_into().unwrap());
        let e_phoff = u32::from_le_bytes(data[28..32].try_into().unwrap()) as usize;
        let e_phentsize = u16::from_le_bytes(data[42..44].try_into().unwrap()) as usize;
        let e_phnum = u16::from_le_bytes(data[44..46].try_into().unwrap()) as usize;

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

        let dest = FLASH_BASE.wrapping_add(flash_offset);
        for (i, &b) in data.iter().enumerate() {
            bus.write_u8(dest.wrapping_add(i as u32), b);
        }

        Ok(data.len())
    }
}
