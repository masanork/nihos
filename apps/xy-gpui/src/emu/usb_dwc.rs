//! Test-only, disconnected P4 USB2 host fixture. No transfers or devices.
use std::collections::HashMap;

pub struct Usb {
    registers: HashMap<u32, u32>,
}

impl Usb {
    pub fn new() -> Self {
        Self {
            registers: HashMap::new(),
        }
    }

    pub fn read(&mut self, offset: u32) -> Result<u32, String> {
        match offset {
            0x40 => Ok(0x4f54_430a),           // synthetic DWC 4.30a core identity
            0x48 => Ok((15 << 14) | (1 << 6)), // synthetic 16 channels, HS PHY
            0x4c => Ok(1024 << 16),            // synthetic FIFO depth in 32-bit words
            0x10 => Ok(1 << 31),               // idle; modeled FIFO flushes complete immediately
            0x14 => Ok(u32::from(
                self.registers.get(&0x0c).copied().unwrap_or(0) & (1 << 29) != 0,
            )),
            0x00 | 0x04 | 0x08 | 0x0c | 0x18 | 0x24 | 0x28 | 0x5c | 0x100 | 0x400 | 0x404
            | 0x408 | 0x414 | 0x418 | 0x41c | 0x440 | 0xe00 => {
                Ok(self.registers.get(&offset).copied().unwrap_or(0))
            }
            _ => Err(format!("unsupported USB DWC read offset {offset:#x}")),
        }
    }

    pub fn write(&mut self, offset: u32, value: u32) -> Result<(), String> {
        match offset {
            0x10 => {
                // FIFO flush operations only. Core reset requires its own state machine.
                if value & !(0x7f0 | (1 << 31)) != 0 {
                    return Err(format!("unsupported USB DWC reset command {value:#x}"));
                }
            }
            0x14 => {} // no pending events; interrupt bits are W1C
            0x440 => {
                // With no attached device only the software port-power control is modeled.
                if value & !((1 << 12) | 0x2a) != 0 {
                    return Err(format!("unsupported USB DWC port command {value:#x}"));
                }
                self.registers.insert(offset, value & (1 << 12));
            }
            0x00 | 0x04 | 0x08 | 0x0c | 0x18 | 0x24 | 0x28 | 0x5c | 0x100 | 0x400 | 0x404
            | 0x418 | 0x41c | 0xe00 => {
                self.registers.insert(offset, value);
            }
            _ => return Err(format!("unsupported USB DWC write offset {offset:#x}")),
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disconnected_port_stays_disconnected_and_rejects_transfers() {
        let mut usb = Usb::new();
        assert_eq!(usb.read(0x40).unwrap(), 0x4f54_430a);
        assert_eq!(usb.read(0x10).unwrap(), 1 << 31);
        usb.write(0x10, (1 << 31) | (1 << 5)).unwrap();
        assert_eq!(usb.read(0x10).unwrap(), 1 << 31);
        usb.write(0x440, 1 << 12).unwrap();
        assert_eq!(usb.read(0x440).unwrap(), 1 << 12);
        usb.write(0x14, u32::MAX).unwrap();
        assert_eq!(usb.read(0x14).unwrap() & !1, 0);
        assert!(usb.write(0x500, 1 << 31).is_err());
        assert!(usb.write(0x440, 1 << 8).is_err());
    }
}
