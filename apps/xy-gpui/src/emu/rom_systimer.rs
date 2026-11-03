//! Limited ROM HAL configuration against the functional SYSTIMER register map.
use super::bus::Bus;
const BASE: u32 = 0x500e_2000;

fn validate_context(bus: &mut Bus, ctx: u32) -> Result<(), String> {
    let start = u64::from(ctx);
    let end = start + 4;
    let valid = ctx & 3 == 0
        && [
            (0x3010_0000, 0x3010_2000),
            (0x4800_0000, 0x4a00_0000),
            (0x4ff0_0000, 0x5000_0000),
            (0x5010_8000, 0x5011_0000),
        ]
        .iter()
        .any(|&(a, b)| start >= a && end <= b);
    if !valid || bus.read_u32(ctx) != BASE {
        return Err("invalid systimer HAL context".into());
    }
    Ok(())
}

pub fn counter(bus: &mut Bus, ctx: u32, counter: u32) -> Result<u64, String> {
    validate_context(bus, ctx)?;
    if counter >= 2 {
        return Err("invalid systimer counter".into());
    }
    bus.write_u32(BASE + 4 + counter * 4, 1 << 30);
    let hi = bus.read_u32(BASE + 0x40 + counter * 8);
    let lo = bus.read_u32(BASE + 0x44 + counter * 8);
    Ok((u64::from(hi) << 32) | u64::from(lo))
}

pub fn call(
    bus: &mut Bus,
    pc: u32,
    ctx: u32,
    first: u32,
    second: u32,
    third: u32,
) -> Result<(), String> {
    validate_context(bus, ctx)?;
    let (address, mask, value) = match pc {
        0x4fc0_0254 if first < 2 => (BASE, 1u32 << (30 - first), 1u32 << (30 - first)),
        0x4fc0_0258 if first < 3 && second < 2 => {
            (BASE + 0x34 + first * 4, 1u32 << 30, second << 30)
        }
        0x4fc0_025c if first < 3 && second < 2 => {
            (BASE + 0x34 + first * 4, 1u32 << 31, second << 31)
        }
        0x4fc0_0260 if first < 2 && second < 2 && third < 2 => {
            let mask = 1u32 << (28 - first * 2 - second);
            (BASE, mask, if third == 1 { mask } else { 0 })
        }
        _ => {
            return Err(format!(
                "unsupported systimer HAL operation {pc:#010x}, args={first},{second},{third}"
            ));
        }
    };
    let current = bus.read_u32(address);
    bus.write_u32(address, (current & !mask) | value);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snapshots_follow_enabled_counters_and_remain_stable() {
        let mut bus = Bus::new();
        let ctx = 0x4ff0_0100;
        bus.write_u32(ctx, BASE);
        bus.timer_ticks = 360;
        assert_eq!(counter(&mut bus, ctx, 0).unwrap(), 0);
        call(&mut bus, 0x4fc0_0254, ctx, 0, 0, 0).unwrap();
        bus.timer_ticks += 360;
        assert_eq!(counter(&mut bus, ctx, 0).unwrap(), 16);
        assert_eq!(bus.read_u32(BASE + 4) & (1 << 29), 1 << 29);
        bus.timer_ticks += 360;
        assert_eq!(bus.read_u32(BASE + 0x44), 16);
        assert_eq!(counter(&mut bus, ctx, 1).unwrap(), 0);
        bus.write_u32(BASE + 4, 1 << 29);
        assert_eq!(bus.read_u32(BASE + 4) & (1 << 29), 0);
        bus.write_u32(BASE, 0);
        bus.timer_ticks += 360;
        assert_eq!(counter(&mut bus, ctx, 0).unwrap(), 32);
        assert!(counter(&mut bus, ctx, 2).is_err());
    }
    #[test]
    fn configures_selected_counter_alarm_and_stall_without_touching_others() {
        let mut bus = Bus::new();
        let ctx = 0x4ff0_0100;
        bus.write_u32(ctx, BASE);
        bus.write_u32(BASE, 0x40);
        call(&mut bus, 0x4fc0_0254, ctx, 1, 0, 0).unwrap();
        call(&mut bus, 0x4fc0_0260, ctx, 1, 0, 1).unwrap();
        call(&mut bus, 0x4fc0_0258, ctx, 2, 1, 0).unwrap();
        call(&mut bus, 0x4fc0_025c, ctx, 2, 1, 0).unwrap();
        assert_eq!(bus.read_u32(BASE), 0x40 | (1 << 29) | (1 << 26));
        assert_eq!(bus.read_u32(BASE + 0x3c), 0xc000_0000);
        assert_eq!(bus.read_u32(BASE + 0x34), 0);
        assert!(call(&mut bus, 0x4fc0_025c, ctx, 3, 1, 0).is_err());
        assert!(call(&mut bus, 0x4fc0_0254, 0x5000_0000, 0, 0, 0).is_err());
        assert_eq!(bus.read_u32(BASE + 0x3c), 0xc000_0000);
    }
}
