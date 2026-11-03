//! Functional RTC watchdog configuration, without reset timing emulation.
use super::bus::Bus;

#[derive(Debug)]
pub struct Watchdog {
    pub protected: bool,
    pub stage0: Option<(u32, u32)>,
    pub feeds: u64,
}
impl Default for Watchdog {
    fn default() -> Self {
        Self {
            protected: true,
            stage0: None,
            feeds: 0,
        }
    }
}

pub fn call(
    bus: &mut Bus,
    pc: u32,
    context: u32,
    stage: u32,
    timeout: u32,
    action: u32,
) -> Result<(), String> {
    let end = u64::from(context) + 8;
    let valid_context = context & 3 == 0
        && [
            (0x3010_0000, 0x3010_2000),
            (0x4800_0000, 0x4a00_0000),
            (0x4ff0_0000, 0x5000_0000),
            (0x5010_8000, 0x5011_0000),
        ]
        .iter()
        .any(|&(a, b)| u64::from(context) >= a && end <= b);
    if !valid_context || bus.read_u32(context) != 0 || bus.read_u32(context + 4) != 0x5011_6000 {
        return Err(format!("unsupported RTC watchdog context {context:#010x}"));
    }
    match pc {
        0x4fc0_0208 => bus.rom_wdt.protected = false,
        0x4fc0_020c => bus.rom_wdt.protected = true,
        0x4fc0_0214 if !bus.rom_wdt.protected => {
            let value = bus.read_u32(0x5011_6000);
            bus.write_u32(0x5011_6000, value & !(1 << 31));
        }
        0x4fc0_021c if !bus.rom_wdt.protected => bus.rom_wdt.feeds += 1,
        0x4fc0_0204 if !bus.rom_wdt.protected && stage == 0 && action == 4 => {
            bus.rom_wdt.stage0 = Some((timeout, action));
        }
        _ => {
            return Err(format!(
                "unsupported or protected RTC watchdog operation {pc:#010x}, stage={stage}, action={action}"
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn watchdog_requires_valid_context_and_unlocked_stage() {
        let mut bus = Bus::new();
        let ctx = 0x4ff0_0100;
        bus.write_u32(ctx, 0);
        bus.write_u32(ctx + 4, 0x5011_6000);
        assert!(call(&mut bus, 0x4fc0_0204, ctx, 0, 123, 4).is_err());
        bus.write_u32(0x5011_6000, 0x8000_0300);
        assert!(call(&mut bus, 0x4fc0_0214, ctx, 0, 0, 0).is_err());
        assert_eq!(bus.read_u32(0x5011_6000), 0x8000_0300);
        call(&mut bus, 0x4fc0_0208, ctx, 0, 0, 0).unwrap();
        call(&mut bus, 0x4fc0_0214, ctx, 0, 0, 0).unwrap();
        assert_eq!(bus.read_u32(0x5011_6000), 0x300);
        call(&mut bus, 0x4fc0_021c, ctx, 0, 0, 0).unwrap();
        call(&mut bus, 0x4fc0_0204, ctx, 0, 123, 4).unwrap();
        assert_eq!(bus.rom_wdt.stage0, Some((123, 4)));
        assert_eq!(bus.rom_wdt.feeds, 1);
        assert!(call(&mut bus, 0x4fc0_0204, ctx, 1, 42, 4).is_err());
        assert_eq!(bus.rom_wdt.stage0, Some((123, 4)));
        call(&mut bus, 0x4fc0_020c, ctx, 0, 0, 0).unwrap();
        assert!(call(&mut bus, 0x4fc0_021c, ctx, 0, 0, 0).is_err());
        assert!(call(&mut bus, 0x4fc0_0208, 0x5000_0000, 0, 0, 0).is_err());
        assert!(bus.rom_wdt.protected);
    }
}
