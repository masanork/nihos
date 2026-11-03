//! Bounded qsort bridge which executes the guest comparator on the guest CPU.
use super::{bus::Bus, cpu::Cpu};

pub const RETURN_PC: u32 = 0xffff_fff0;
const MAX_CALLBACK_STEPS: u64 = 1_000_000;

#[derive(Debug)]
pub struct Sort {
    base: u32,
    count: u32,
    size: u32,
    comparator: u32,
    i: u32,
    j: u32,
    return_pc: u32,
    stack: u32,
    callback_started: u64,
    mmu_generation: Option<u64>,
}

fn ram(address: u32, size: u64) -> bool {
    let start = u64::from(address);
    let end = start + size;
    [
        (0x3010_0000, 0x3010_2000),
        (0x4800_0000, 0x4a00_0000),
        (0x4ff0_0000, 0x5000_0000),
        (0x5010_8000, 0x5011_0000),
    ]
    .iter()
    .any(|&(a, b)| start >= a && end <= b)
}

fn call_comparator(cpu: &mut Cpu, mut sort: Sort) {
    sort.callback_started = cpu.instructions_executed;
    cpu.x[10] = sort.base + (sort.j - 1) * sort.size;
    cpu.x[11] = sort.base + sort.j * sort.size;
    cpu.x[1] = RETURN_PC;
    cpu.pc = sort.comparator;
    cpu.qsort = Some(sort);
}

pub fn begin(cpu: &mut Cpu, bus: &Bus) -> Result<(), String> {
    let (base, count, size, comparator) = (cpu.x[10], cpu.x[11], cpu.x[12], cpu.x[13]);
    if cpu.qsort.is_some() {
        return Err("nested qsort is unsupported".into());
    }
    if count > 256 || size == 0 || size > 1024 || u64::from(count) * u64::from(size) > 65536 {
        return Err("qsort bounds exceeded".into());
    }
    if count == 0 {
        cpu.pc = cpu.x[1];
        return Ok(());
    }
    if !ram(base, u64::from(count) * u64::from(size))
        || !bus.mapped_backing_range(base, u64::from(count) * u64::from(size))
    {
        return Err("qsort array outside RAM".into());
    }
    if count == 1 {
        cpu.pc = cpu.x[1];
        return Ok(());
    }
    if comparator & 1 != 0
        || !bus.mapped_backing_range(comparator, 2)
        || ![
            (0x3010_0000, 0x3010_2000),
            (0x4000_0000, 0x4100_0000),
            (0x4ff0_0000, 0x5000_0000),
        ]
        .iter()
        .any(|&(a, b)| comparator >= a && comparator < b)
    {
        return Err(format!("unsupported qsort comparator {comparator:#010x}"));
    }
    let sort = Sort {
        base,
        count,
        size,
        comparator,
        i: 1,
        j: 1,
        return_pc: cpu.x[1],
        stack: cpu.x[2],
        callback_started: 0,
        mmu_generation: (0x4800_0000..0x4a00_0000)
            .contains(&base)
            .then_some(bus.mmu_generation),
    };
    call_comparator(cpu, sort);
    Ok(())
}

pub fn check_budget(cpu: &Cpu) -> Result<(), String> {
    if let Some(sort) = &cpu.qsort
        && cpu
            .instructions_executed
            .saturating_sub(sort.callback_started)
            > MAX_CALLBACK_STEPS
    {
        return Err("qsort comparator exceeded instruction budget".into());
    }
    Ok(())
}

pub fn returned(cpu: &mut Cpu, bus: &mut Bus) -> Result<(), String> {
    let mut sort = cpu.qsort.take().ok_or("unexpected qsort return")?;
    if cpu.x[2] != sort.stack {
        return Err("qsort comparator did not restore stack".into());
    }
    if sort
        .mmu_generation
        .is_some_and(|generation| generation != bus.mmu_generation)
        || !bus.mapped_backing_range(sort.base, u64::from(sort.count) * u64::from(sort.size))
    {
        return Err("qsort array mapping changed during comparator".into());
    }
    if (cpu.x[10] as i32) > 0 {
        let left = sort.base + (sort.j - 1) * sort.size;
        let right = left + sort.size;
        for offset in 0..sort.size {
            let a = bus.read_u8(left + offset);
            let b = bus.read_u8(right + offset);
            bus.write_u8(left + offset, b);
            bus.write_u8(right + offset, a);
        }
        sort.j -= 1;
        if sort.j != 0 {
            call_comparator(cpu, sort);
            return Ok(());
        }
    }
    sort.i += 1;
    if sort.i == sort.count {
        cpu.x[1] = sort.return_pc;
        cpu.pc = sort.return_pc;
    } else {
        sort.j = sort.i;
        call_comparator(cpu, sort);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_unmapped_arrays_and_mapping_changes_before_swapping() {
        let mut bus = Bus::new();
        bus.write_u32(0x5008_e380, 1);
        bus.write_u32(0x5008_e37c, 0);
        let mut invalid = Cpu::new(0x4fc0_0348);
        invalid.x[10..14].copy_from_slice(&[0x4800_fffc, 2, 4, 0x4ff0_0200]);
        assert!(!invalid.step(&mut bus));
        assert!(invalid.fault.unwrap().contains("outside RAM"));

        bus.write_u32(0x4800_0100, 2);
        bus.write_u32(0x4800_0104, 1);
        let mut cpu = Cpu::new(0x4fc0_0348);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10..14].copy_from_slice(&[0x4800_0100, 2, 4, 0x4ff0_0200]);
        assert!(cpu.step(&mut bus));
        bus.write_u32(0x5008_e380, 0);
        bus.write_u32(0x5008_e37c, 0xc02);
        cpu.pc = RETURN_PC;
        cpu.x[10] = 1;
        assert!(!cpu.step(&mut bus));
        assert!(cpu.fault.unwrap().contains("mapping changed"));
        assert_eq!(&bus.psram[0x100..0x108], &[2, 0, 0, 0, 1, 0, 0, 0]);
        assert_eq!(&bus.psram[0x20100..0x20108], &[0; 8]);
    }
    #[test]
    fn sorts_by_executing_guest_comparator_and_returns_to_caller() {
        let mut bus = Bus::new();
        let comparator = 0x4ff0_0200;
        for (i, instruction) in [0x0005_2503u32, 0x0005_a583, 0x40b5_0533, 0x0000_8067]
            .iter()
            .enumerate()
        {
            bus.write_u32(comparator + i as u32 * 4, *instruction);
        }
        let base = 0x4ff0_0300;
        for (i, value) in [3, 0, 2, 1].iter().enumerate() {
            bus.write_u32(base + i as u32 * 4, *value);
        }
        let mut cpu = Cpu::new(0x4fc0_0348);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10..14].copy_from_slice(&[base, 4, 4, comparator]);
        for _ in 0..1000 {
            if cpu.pc == 0x4ff0_0100 {
                break;
            }
            assert!(cpu.step(&mut bus), "{:?}", cpu.fault);
        }
        assert_eq!(cpu.pc, 0x4ff0_0100);
        assert_eq!(cpu.x[1], 0x4ff0_0100);
        assert_eq!(
            (0..4)
                .map(|i| bus.read_u32(base + i * 4))
                .collect::<Vec<_>>(),
            vec![0, 1, 2, 3]
        );
        assert!(cpu.instructions_executed > 4);
    }

    #[test]
    fn respects_guest_comparator_order() {
        let mut bus = Bus::new();
        let comparator = 0x4ff0_0200;
        // Return right - left, reversing the order from the ascending test.
        for (i, instruction) in [0x0005_2503u32, 0x0005_a583, 0x40a5_8533, 0x0000_8067]
            .iter()
            .enumerate()
        {
            bus.write_u32(comparator + i as u32 * 4, *instruction);
        }
        let base = 0x4ff0_0300;
        for (i, value) in [0, 3, 1, 2].iter().enumerate() {
            bus.write_u32(base + i as u32 * 4, *value);
        }
        let mut cpu = Cpu::new(0x4fc0_0348);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10..14].copy_from_slice(&[base, 4, 4, comparator]);
        for _ in 0..1000 {
            if cpu.pc == 0x4ff0_0100 {
                break;
            }
            assert!(cpu.step(&mut bus), "{:?}", cpu.fault);
        }
        assert_eq!(cpu.pc, 0x4ff0_0100);
        assert_eq!(
            (0..4)
                .map(|i| bus.read_u32(base + i * 4))
                .collect::<Vec<_>>(),
            vec![3, 2, 1, 0]
        );
    }
    #[test]
    fn rejects_unsafe_arrays_and_broken_callback_stack() {
        let mut bus = Bus::new();
        let mut cpu = Cpu::new(0x4fc0_0348);
        cpu.x[1] = 0x4ff0_0100;
        cpu.x[10..14].copy_from_slice(&[0x5000_0000, 4, 4, 0x4ff0_0200]);
        assert!(!cpu.step(&mut bus));
        assert!(cpu.fault.as_ref().unwrap().contains("outside RAM"));
        cpu.fault = None;
        cpu.pc = 0x4fc0_0348;
        cpu.x[10] = 0x4ff0_0300;
        assert!(cpu.step(&mut bus));
        cpu.pc = RETURN_PC;
        cpu.x[2] -= 16;
        assert!(!cpu.step(&mut bus));
        assert!(cpu.fault.as_ref().unwrap().contains("restore stack"));
    }
}
