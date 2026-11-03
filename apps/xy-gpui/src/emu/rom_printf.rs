//! Bounded subset of the P4 ROM printf ABI. Unsupported formats fail closed.
use super::{bus::Bus, cpu::Cpu};

pub(super) fn readable(start: u32, len: usize) -> bool {
    let end = start as u64 + len as u64;
    [
        (0x3010_0000, 0x3010_2000),
        (0x4000_0000, 0x4100_0000),
        (0x4800_0000, 0x4a00_0000),
        (0x4ff0_0000, 0x5000_0000),
        (0x5010_8000, 0x5011_0000),
    ]
    .iter()
    .any(|&(a, b)| start as u64 >= a && end <= b)
}

pub(super) fn c_string(bus: &mut Bus, start: u32) -> Result<Vec<u8>, String> {
    let mut result = Vec::new();
    for offset in 0..4096u32 {
        let address = start.checked_add(offset).ok_or("string pointer overflow")?;
        if !readable(address, 1) || !bus.mapped_backing_range(address, 1) {
            return Err(format!("unmapped string at {address:#010x}"));
        }
        let byte = bus.read_u8(address);
        if byte == 0 {
            return Ok(result);
        }
        result.push(byte);
    }
    Err("unterminated or oversized string".into())
}

fn argument(cpu: &Cpu, bus: &mut Bus, index: usize) -> Result<u32, String> {
    if index < 7 {
        return Ok(cpu.x[11 + index]);
    }
    let offset = ((index - 7) as u32)
        .checked_mul(4)
        .ok_or("argument offset overflow")?;
    let addr = cpu.x[2]
        .checked_add(offset)
        .ok_or("stack address overflow")?;
    if addr & 3 != 0 || !readable(addr, 4) || !bus.mapped_backing_range(addr, 4) {
        return Err(format!("invalid argument stack at {addr:#010x}"));
    }
    Ok(bus.read_u32(addr))
}

pub fn format(cpu: &Cpu, bus: &mut Bus) -> Result<Vec<u8>, String> {
    let fmt = c_string(bus, cpu.x[10])?;
    let mut out = Vec::new();
    let mut i = 0;
    let mut arg = 0;
    while i < fmt.len() {
        if out.len() >= 8192 {
            return Err("printf output exceeds 8192 bytes".into());
        }
        if fmt[i] != b'%' {
            out.push(fmt[i]);
            i += 1;
            continue;
        }
        i += 1;
        if fmt.get(i) == Some(&b'%') {
            out.push(b'%');
            i += 1;
            continue;
        }
        let zero = fmt.get(i) == Some(&b'0');
        if zero {
            i += 1;
        }
        let mut width = 0usize;
        while let Some(&digit @ b'0'..=b'9') = fmt.get(i) {
            width = width
                .checked_mul(10)
                .and_then(|v| v.checked_add((digit - b'0') as usize))
                .ok_or("width overflow")?;
            if width > 64 {
                return Err("printf width exceeds 64".into());
            }
            i += 1;
        }
        let long = fmt.get(i) == Some(&b'l');
        if long {
            i += 1;
        }
        let spec = *fmt.get(i).ok_or("incomplete printf format")?;
        if !matches!(spec, b's' | b'd' | b'i' | b'u' | b'x' | b'X' | b'c') {
            return Err(format!(
                "unsupported printf conversion %{spec}",
                spec = spec as char
            ));
        }
        if long && matches!(spec, b's' | b'c') {
            return Err("wide printf arguments are unsupported".into());
        }
        let value = argument(cpu, bus, arg)?;
        arg += 1;
        let mut rendered = match spec {
            b's' => c_string(bus, value)?,
            b'd' | b'i' => (value as i32).to_string().into_bytes(),
            b'u' => value.to_string().into_bytes(),
            b'x' => format!("{value:x}").into_bytes(),
            b'X' => format!("{value:X}").into_bytes(),
            b'c' => vec![value as u8],
            _ => unreachable!(),
        };
        let padding = width.saturating_sub(rendered.len());
        if padding != 0 {
            let sign = zero && rendered.first() == Some(&b'-');
            if sign {
                out.push(b'-');
                rendered.remove(0);
            }
            out.extend(std::iter::repeat_n(if zero { b'0' } else { b' ' }, padding));
        }
        out.extend(rendered);
        if out.len() > 8192 {
            return Err("printf output exceeds 8192 bytes".into());
        }
        i += 1;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn put(bus: &mut Bus, address: u32, text: &[u8]) {
        for (i, byte) in text.iter().enumerate() {
            bus.write_u8(address + i as u32, *byte);
        }
    }
    #[test]
    fn renders_register_and_stack_arguments() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0024);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10] = 0x4ff0_0200;
        put(&mut bus, cpu.x[10], b"%s %lu %08x %d %u %u %u %u %%\0");
        put(&mut bus, 0x4ff0_0300, b"tag\0");
        cpu.x[11..18].copy_from_slice(&[0x4ff0_0300, 42, 0xab, (-7i32) as u32, 5, 6, 7]);
        bus.write_u32(cpu.x[2], 8);
        assert!(cpu.step(&mut bus));
        assert_eq!(bus.console_output, b"tag 42 000000ab -7 5 6 7 8 %");
        assert_eq!(cpu.x[10] as usize, bus.console_output.len());
        assert_eq!(cpu.pc, 0x4ff0_0100);
    }
    #[test]
    fn invalid_format_and_pointer_emit_no_partial_output() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0024);
        cpu.x[10] = 0x4ff0_0200;
        put(&mut bus, cpu.x[10], b"prefix %n\0");
        assert!(!cpu.step(&mut bus));
        assert!(
            cpu.fault
                .as_ref()
                .unwrap()
                .contains("unsupported printf conversion")
        );
        assert!(bus.console_output.is_empty());
        cpu.fault = None;
        cpu.pc = 0x4fc0_0024;
        put(&mut bus, cpu.x[10], b"prefix %s\0");
        cpu.x[11] = 0x5000_0000;
        assert!(!cpu.step(&mut bus));
        assert!(bus.console_output.is_empty());
    }
}
