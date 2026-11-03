//! RV32IMAFC CPU emulator for nihos firmware execution.

use super::bus::Bus;
use rustc_apfloat::{Float, Round, Status, ieee::Single};

pub struct Cpu {
    pub x: [u32; 32],
    pub f: [f32; 32],
    pub pc: u32,

    // CSRs
    pub mstatus: u32,
    pub mie: u32,
    pub mtvec: u32,
    pub mtvt: u32,
    pub mscratch: u32,
    pub mepc: u32,
    pub mcause: u32,
    pub mtval: u32,
    pub mip: u32,
    pub mhartid: u32,
    pub fcsr: u32,
    in_interrupt: bool,

    pub instructions_executed: u64,
    pub fault: Option<String>,
    pub(super) qsort: Option<super::rom_qsort::Sort>,
}

impl Cpu {
    pub fn new(entry_pc: u32) -> Self {
        let mut cpu = Self {
            x: [0; 32],
            f: [0.0; 32],
            pc: entry_pc,
            mstatus: 0x1800, // MPP = Machine mode
            mie: 0,
            mtvec: 0,
            mtvt: 0,
            mscratch: 0,
            mepc: 0,
            mcause: 0,
            mtval: 0,
            mip: 0,
            mhartid: 0,
            fcsr: 0,
            in_interrupt: false,
            instructions_executed: 0,
            fault: None,
            qsort: None,
        };
        // Initial stack pointer: 0x4ff6e000 (standard nihos stack top)
        cpu.x[2] = 0x4ff6_e000;
        cpu
    }

    pub fn reg(&self, idx: u32) -> u32 {
        if idx == 0 { 0 } else { self.x[idx as usize] }
    }

    pub fn set_reg(&mut self, idx: u32, val: u32) {
        if idx != 0 {
            self.x[idx as usize] = val;
        }
    }

    fn fp_rounding(&self, encoded: u32) -> Option<Round> {
        let rm = if encoded == 7 {
            (self.fcsr >> 5) & 7
        } else {
            encoded
        };
        match rm {
            0 => Some(Round::NearestTiesToEven),
            1 => Some(Round::TowardZero),
            2 => Some(Round::TowardNegative),
            3 => Some(Round::TowardPositive),
            4 => Some(Round::NearestTiesToAway),
            _ => None,
        }
    }

    fn accumulate_fp_status(&mut self, status: Status) {
        for (exception, flag) in [
            (Status::INVALID_OP, 0x10),
            (Status::DIV_BY_ZERO, 0x08),
            (Status::OVERFLOW, 0x04),
            (Status::UNDERFLOW, 0x02),
            (Status::INEXACT, 0x01),
        ] {
            if status.contains(exception) {
                self.fcsr |= flag;
            }
        }
    }

    pub fn step(&mut self, bus: &mut Bus) -> bool {
        if self.fault.is_some() {
            return false;
        }
        bus.active_hart = self.mhartid as usize;
        if let Err(error) = super::rom_qsort::check_budget(self) {
            self.fault = Some(error);
            return false;
        }
        if !self.in_interrupt
            && self.instructions_executed & 63 == 0
            && self.mstatus & 8 != 0
            && let Some(line) = bus.pending_irq(self.mhartid as usize)
        {
            self.mepc = self.pc;
            self.mcause = 0x8000_0000 | line;
            self.mtval = 0;
            self.mstatus = (self.mstatus & !(1 << 3)) | (1 << 7) | (3 << 11);
            self.in_interrupt = true;
            if bus.irq_vectored(self.mhartid as usize, line) {
                let entry = self.mtvt.wrapping_add(line * 4);
                if self.mtvt == 0 || !(0x4ff0_0000..0x5000_0000).contains(&entry) {
                    self.fault = Some(format!("unsupported CLIC vector table {:#010x}", self.mtvt));
                    return false;
                }
                self.pc = bus.read_u32(entry);
                if self.pc & 1 != 0 || !(0x4ff0_0000..0x5000_0000).contains(&self.pc) {
                    self.fault = Some(format!("unsupported CLIC vector {:#010x}", self.pc));
                    return false;
                }
            } else {
                self.pc = self.mtvec & !0x3f;
            }
        }
        // Handle timer ticks periodically
        if self.instructions_executed & 0xff == 0 {
            bus.timer_ticks = bus.timer_ticks.wrapping_add(256);
        }

        if self.pc == super::rom_qsort::RETURN_PC {
            if let Err(error) = super::rom_qsort::returned(self, bus) {
                self.fault = Some(error);
            }
            self.instructions_executed += 1;
            return self.fault.is_none();
        }

        // The optional ELF-backed investigation mode executes ROM internals;
        // public jump-table entries still use the modeled ROM call boundary.
        if (0x4fc0_0000..=0x4fc1_ffff).contains(&self.pc) {
            let executable = bus.rom_execute
                && self.pc >= 0x4fc0_0b00
                && bus.rom_executable.iter().any(|&(start, end)| {
                    self.pc >= start && self.pc.checked_add(4).is_some_and(|pc| pc <= end)
                });
            if !executable {
                self.handle_rom_call(bus);
                if self.fault.is_none() {
                    self.fault = bus.fault.take();
                }
                self.instructions_executed += 1;
                return self.fault.is_none();
            }
        }

        // Fetch instruction (support 16-bit compressed or 32-bit standard)
        let raw16 = bus.read_u16(self.pc);
        if let Some(error) = bus.fault.take() {
            self.fault = Some(error);
            self.instructions_executed += 1;
            return false;
        }
        if (raw16 & 0x03) != 0x03 {
            // Compressed 16-bit instruction (RVC)
            self.execute_c(raw16, bus);
            self.instructions_executed += 1;
            if self.fault.is_none() {
                self.fault = bus.fault.take();
            }
            return self.fault.is_none();
        }

        let inst = bus.read_u32(self.pc);
        self.execute_32(inst, bus);
        self.instructions_executed += 1;
        if self.fault.is_none() {
            self.fault = bus.fault.take();
        }
        self.fault.is_none()
    }

    fn execute_32(&mut self, inst: u32, bus: &mut Bus) {
        let opcode = inst & 0x7f;
        let rd = (inst >> 7) & 0x1f;
        let funct3 = (inst >> 12) & 0x07;
        let rs1 = (inst >> 15) & 0x1f;
        let rs2 = (inst >> 20) & 0x1f;
        let funct7 = (inst >> 25) & 0x7f;

        let mut next_pc = self.pc.wrapping_add(4);

        match opcode {
            // FCVT.WU.S clips invalid results per RISC-V, not APFloat's NaN default.
            0x53 if funct7 == 0x60 && rs2 == 1 => {
                if let Some(rounding) = self.fp_rounding(funct3) {
                    let source = Single::from_bits(self.f[rs1 as usize].to_bits().into());
                    let mut exact = false;
                    let result = source.to_u128_r(32, rounding, &mut exact);
                    self.set_reg(
                        rd,
                        if source.is_nan() {
                            u32::MAX
                        } else {
                            result.value as u32
                        },
                    );
                    self.accumulate_fp_status(result.status);
                } else {
                    self.fault = Some(format!(
                        "invalid floating-point rounding mode at {:#010x}",
                        self.pc
                    ));
                }
            }
            // FLW preserves the exact payload bits, including signaling NaNs.
            0x07 if funct3 == 2 => {
                let offset = ((inst as i32) >> 20) as u32;
                let bits = bus.read_u32(self.reg(rs1).wrapping_add(offset));
                if bus.fault.is_none() {
                    self.f[rd as usize] = f32::from_bits(bits);
                }
            }
            // FMUL.S / FDIV.S with RISC-V rounding, canonical NaNs and sticky flags.
            0x53 if funct7 == 0x08 || funct7 == 0x0c => {
                let rm = if funct3 == 7 {
                    (self.fcsr >> 5) & 7
                } else {
                    funct3
                };
                let rounding = self.fp_rounding(funct3);
                if let Some(rounding) = rounding {
                    let left = Single::from_bits(self.f[rs1 as usize].to_bits().into());
                    let right = Single::from_bits(self.f[rs2 as usize].to_bits().into());
                    let result = if funct7 == 0x08 {
                        left.mul_r(right, rounding)
                    } else {
                        left.div_r(right, rounding)
                    };
                    let bits = if result.value.is_nan() {
                        0x7fc0_0000
                    } else {
                        result.value.to_bits() as u32
                    };
                    self.f[rd as usize] = f32::from_bits(bits);
                    self.accumulate_fp_status(result.status);
                } else {
                    self.fault = Some(format!(
                        "invalid floating-point rounding mode {rm} at {:#010x}",
                        self.pc
                    ));
                }
            }
            // FCVT.S.WU: unsigned RV32 integer to IEEE-754 binary32.
            0x53 if funct7 == 0x68 && rs2 == 1 => {
                let rm = if funct3 == 7 {
                    (self.fcsr >> 5) & 7
                } else {
                    funct3
                };
                if rm > 4 {
                    self.fault = Some(format!(
                        "invalid floating-point rounding mode {rm} at {:#010x}",
                        self.pc
                    ));
                } else {
                    let value = self.reg(rs1) as u64;
                    let exponent = 63u32.saturating_sub(value.leading_zeros());
                    let shift = exponent.saturating_sub(23);
                    let unit = 1u64 << shift;
                    let remainder = value & (unit - 1);
                    let base = value - remainder;
                    let increment = match rm {
                        0 => {
                            remainder * 2 > unit
                                || (remainder * 2 == unit && (base / unit) & 1 != 0)
                        }
                        1 | 2 => false,
                        3 => remainder != 0,
                        4 => remainder != 0 && remainder * 2 >= unit,
                        _ => unreachable!(),
                    };
                    self.f[rd as usize] = (base + if increment { unit } else { 0 }) as f32;
                    if remainder != 0 {
                        self.fcsr |= 1;
                    }
                }
            }
            // LUI
            0x37 => {
                self.set_reg(rd, inst & 0xffff_f000);
            }
            // AUIPC
            0x17 => {
                let imm = inst & 0xffff_f000;
                self.set_reg(rd, self.pc.wrapping_add(imm));
            }
            // JAL
            0x6f => {
                let imm = (((inst >> 31) & 1) << 20)
                    | (((inst >> 12) & 0xff) << 12)
                    | (((inst >> 20) & 1) << 11)
                    | (((inst >> 21) & 0x3ff) << 1);
                let imm = ((imm as i32) << 11) >> 11; // Sign extend
                self.set_reg(rd, next_pc);
                next_pc = self.pc.wrapping_add(imm as u32);
            }
            // JALR
            0x67 => {
                let imm = ((inst as i32) >> 20) as u32;
                let target = (self.reg(rs1).wrapping_add(imm)) & !1;
                self.set_reg(rd, next_pc);
                next_pc = target;
            }
            // Branch
            0x63 => {
                let imm = (((inst >> 31) & 1) << 12)
                    | (((inst >> 7) & 1) << 11)
                    | (((inst >> 25) & 0x3f) << 5)
                    | (((inst >> 8) & 0x0f) << 1);
                let imm = ((imm as i32) << 19) >> 19; // Sign extend
                let v1 = self.reg(rs1);
                let v2 = self.reg(rs2);
                let take = match funct3 {
                    0x0 => v1 == v2,                   // BEQ
                    0x1 => v1 != v2,                   // BNE
                    0x4 => (v1 as i32) < (v2 as i32),  // BLT
                    0x5 => (v1 as i32) >= (v2 as i32), // BGE
                    0x6 => v1 < v2,                    // BLTU
                    0x7 => v1 >= v2,                   // BGEU
                    _ => false,
                };
                if take {
                    next_pc = self.pc.wrapping_add(imm as u32);
                }
            }
            // Load
            0x03 => {
                let imm = ((inst as i32) >> 20) as u32;
                let addr = self.reg(rs1).wrapping_add(imm);
                let val = match funct3 {
                    0x0 => (bus.read_u8(addr) as i8 as i32) as u32, // LB
                    0x1 => (bus.read_u16(addr) as i16 as i32) as u32, // LH
                    0x2 => bus.read_u32(addr),                      // LW
                    0x4 => bus.read_u8(addr) as u32,                // LBU
                    0x5 => bus.read_u16(addr) as u32,               // LHU
                    _ => 0,
                };
                self.set_reg(rd, val);
            }
            // Store
            0x23 => {
                let imm = (((inst >> 25) & 0x7f) << 5) | ((inst >> 7) & 0x1f);
                let imm = ((imm as i32) << 20) >> 20; // Sign extend
                let addr = self.reg(rs1).wrapping_add(imm as u32);
                let val = self.reg(rs2);
                match funct3 {
                    0x0 => bus.write_u8(addr, val as u8),
                    0x1 => bus.write_u16(addr, val as u16),
                    0x2 => bus.write_u32(addr, val),
                    _ => {}
                }
            }
            // OP-IMM (ADDI, SLTI, ...)
            0x13 => {
                let imm = ((inst as i32) >> 20) as u32;
                let v = self.reg(rs1);
                let shamt = (inst >> 20) & 0x1f;
                let res = match funct3 {
                    0x0 => v.wrapping_add(imm), // ADDI
                    0x1 => v << shamt,          // SLLI
                    0x2 => {
                        if (v as i32) < (imm as i32) {
                            1
                        } else {
                            0
                        }
                    } // SLTI
                    0x3 => {
                        if v < imm {
                            1
                        } else {
                            0
                        }
                    } // SLTIU
                    0x4 => v ^ imm,             // XORI
                    0x5 => {
                        if (funct7 & 0x20) != 0 {
                            ((v as i32) >> shamt) as u32 // SRAI
                        } else {
                            v >> shamt // SRLI
                        }
                    }
                    0x6 => v | imm, // ORI
                    0x7 => v & imm, // ANDI
                    _ => 0,
                };
                self.set_reg(rd, res);
            }
            // OP (ADD, SUB, MUL, DIV, ...)
            0x33 => {
                let v1 = self.reg(rs1);
                let v2 = self.reg(rs2);
                if funct7 == 0x01 {
                    // RV32M Extension
                    let res = match funct3 {
                        0x0 => v1.wrapping_mul(v2),                                      // MUL
                        0x1 => (((v1 as i32 as i64) * (v2 as i32 as i64)) >> 32) as u32, // MULH
                        0x2 => (((v1 as i32 as i64) * (v2 as u64 as i64)) >> 32) as u32, // MULHSU
                        0x3 => (((v1 as u64) * (v2 as u64)) >> 32) as u32,               // MULHU
                        0x4 => {
                            if v2 == 0 {
                                u32::MAX
                            } else {
                                ((v1 as i32).wrapping_div(v2 as i32)) as u32
                            }
                        } // DIV
                        0x5 => v1.checked_div(v2).unwrap_or(u32::MAX),                   // DIVU
                        0x6 => {
                            if v2 == 0 {
                                v1
                            } else {
                                ((v1 as i32).wrapping_rem(v2 as i32)) as u32
                            }
                        } // REM
                        0x7 => {
                            if v2 == 0 {
                                v1
                            } else {
                                v1 % v2
                            }
                        } // REMU
                        _ => 0,
                    };
                    self.set_reg(rd, res);
                } else {
                    let shamt = v2 & 0x1f;
                    let res = match funct3 {
                        0x0 => {
                            if (funct7 & 0x20) != 0 {
                                v1.wrapping_sub(v2)
                            } else {
                                v1.wrapping_add(v2)
                            }
                        } // SUB / ADD
                        0x1 => v1 << shamt, // SLL
                        0x2 => {
                            if (v1 as i32) < (v2 as i32) {
                                1
                            } else {
                                0
                            }
                        } // SLT
                        0x3 => {
                            if v1 < v2 {
                                1
                            } else {
                                0
                            }
                        } // SLTU
                        0x4 => v1 ^ v2,     // XOR
                        0x5 => {
                            if (funct7 & 0x20) != 0 {
                                ((v1 as i32) >> shamt) as u32 // SRA
                            } else {
                                v1 >> shamt // SRL
                            }
                        }
                        0x6 => v1 | v2, // OR
                        0x7 => v1 & v2, // AND
                        _ => 0,
                    };
                    self.set_reg(rd, res);
                }
            }
            // AMO (RV32A Extension: LR, SC, AMOADD, AMOSWAP, etc.)
            0x2f => {
                let funct5 = (inst >> 27) & 0x1f;
                let addr = self.reg(rs1);
                let v2 = self.reg(rs2);
                let orig = bus.read_u32(addr);
                let res = match funct5 {
                    0x00 => {
                        // AMOADD.W
                        let val = orig.wrapping_add(v2);
                        bus.write_u32(addr, val);
                        orig
                    }
                    0x01 => {
                        // AMOSWAP.W
                        bus.write_u32(addr, v2);
                        orig
                    }
                    0x02 => {
                        // LR.W
                        orig
                    }
                    0x03 => {
                        // SC.W
                        bus.write_u32(addr, v2);
                        0 // success
                    }
                    0x04 => {
                        // AMOXOR.W
                        bus.write_u32(addr, orig ^ v2);
                        orig
                    }
                    0x08 => {
                        // AMOOR.W
                        bus.write_u32(addr, orig | v2);
                        orig
                    }
                    0x0c => {
                        // AMOAND.W
                        bus.write_u32(addr, orig & v2);
                        orig
                    }
                    0x10 => {
                        // AMOMIN.W
                        let min_val = if (orig as i32) < (v2 as i32) {
                            orig
                        } else {
                            v2
                        };
                        bus.write_u32(addr, min_val);
                        orig
                    }
                    0x14 => {
                        // AMOMAX.W
                        let max_val = if (orig as i32) > (v2 as i32) {
                            orig
                        } else {
                            v2
                        };
                        bus.write_u32(addr, max_val);
                        orig
                    }
                    0x18 => {
                        // AMOMINU.W
                        let min_val = if orig < v2 { orig } else { v2 };
                        bus.write_u32(addr, min_val);
                        orig
                    }
                    0x1c => {
                        // AMOMAXU.W
                        let max_val = if orig > v2 { orig } else { v2 };
                        bus.write_u32(addr, max_val);
                        orig
                    }
                    _ => orig,
                };
                self.set_reg(rd, res);
            }
            // FENCE
            0x0f => {}
            // SYSTEM (CSR, MRET, ECALL, WFI)
            0x73 => {
                if funct3 == 0 {
                    match funct7 {
                        0x00 => {
                            if rs2 == 0 {
                                // ECALL
                                self.mepc = self.pc;
                                self.mcause = 11; // Machine ECALL
                                self.mtval = 0;
                                let mie = (self.mstatus >> 3) & 1;
                                self.mstatus = (self.mstatus & !(1 << 3)) | (mie << 7);
                                self.mstatus |= 3 << 11; // MPP = 3 (Machine Mode)
                                next_pc = self.mtvec & !0x3f;
                            } else if rs2 == 1 {
                                // EBREAK
                            }
                        }
                        0x18 => {
                            // MRET
                            next_pc = self.mepc;
                            self.in_interrupt = false;
                            let mpie = (self.mstatus >> 7) & 1;
                            self.mstatus = (self.mstatus & !0x88) | (mpie << 3) | (1 << 7);
                        }
                        0x08 => {
                            // WFI (Wait for Interrupt)
                        }
                        _ => {}
                    }
                } else {
                    // CSR instructions
                    let csr = (inst >> 20) & 0xfff;
                    let old_val = self.read_csr(csr, bus);
                    let operand = if (funct3 & 0x04) != 0 {
                        rs1
                    } else {
                        self.reg(rs1)
                    };
                    let new_val = match funct3 & 0x03 {
                        0x1 => operand,            // CSRRW
                        0x2 => old_val | operand,  // CSRRS
                        0x3 => old_val & !operand, // CSRRC
                        _ => old_val,
                    };
                    self.write_csr(csr, new_val);
                    self.set_reg(rd, old_val);
                }
            }
            _ => {
                self.fault = Some(format!(
                    "unsupported instruction {inst:#010x} at {:#010x}",
                    self.pc
                ))
            }
        }

        self.pc = next_pc;
    }

    fn execute_c(&mut self, inst: u16, bus: &mut Bus) {
        let inst = inst as u32;
        let op = inst & 0x03;
        let funct3 = (inst >> 13) & 0x07;
        let mut next_pc = self.pc.wrapping_add(2);

        match op {
            0b00 => match funct3 {
                // C.ADDI4SPN
                0b000 => {
                    let imm = (((inst >> 7) & 0xf) << 6)
                        | (((inst >> 11) & 0x3) << 4)
                        | (((inst >> 5) & 0x1) << 3)
                        | (((inst >> 6) & 0x1) << 2);
                    let rd = 8 + ((inst >> 2) & 0x7);
                    if imm == 0 {
                        self.fault = Some(format!("illegal C.ADDI4SPN at {:#010x}", self.pc));
                        return;
                    }
                    self.set_reg(rd, self.reg(2).wrapping_add(imm));
                }
                // C.LW
                0b010 => {
                    let imm = (((inst >> 5) & 0x1) << 6)
                        | (((inst >> 10) & 0x7) << 3)
                        | (((inst >> 6) & 0x1) << 2);
                    let rs1 = 8 + ((inst >> 7) & 0x7);
                    let rd = 8 + ((inst >> 2) & 0x7);
                    let addr = self.reg(rs1).wrapping_add(imm);
                    self.set_reg(rd, bus.read_u32(addr));
                }
                // C.SW
                0b110 => {
                    let imm = (((inst >> 5) & 0x1) << 6)
                        | (((inst >> 10) & 0x7) << 3)
                        | (((inst >> 6) & 0x1) << 2);
                    let rs1 = 8 + ((inst >> 7) & 0x7);
                    let rs2 = 8 + ((inst >> 2) & 0x7);
                    let addr = self.reg(rs1).wrapping_add(imm);
                    bus.write_u32(addr, self.reg(rs2));
                }
                _ => {
                    self.fault = Some(format!(
                        "unsupported compressed instruction {inst:#06x} at {:#010x}",
                        self.pc
                    ))
                }
            },
            0b01 => match funct3 {
                // C.NOP / C.ADDI
                0b000 => {
                    let rd = (inst >> 7) & 0x1f;
                    let imm = (((inst >> 12) & 1) << 5) | ((inst >> 2) & 0x1f);
                    let imm = ((imm as i16) << 10) >> 10;
                    if rd != 0 {
                        self.set_reg(rd, self.reg(rd).wrapping_add(imm as u32));
                    }
                }
                // C.JAL
                0b001 => {
                    let imm = (((inst >> 12) & 1) << 11)
                        | (((inst >> 8) & 1) << 10)
                        | (((inst >> 9) & 3) << 8)
                        | (((inst >> 6) & 1) << 7)
                        | (((inst >> 7) & 1) << 6)
                        | (((inst >> 2) & 1) << 5)
                        | (((inst >> 11) & 1) << 4)
                        | (((inst >> 3) & 7) << 1);
                    let imm = ((imm as i16) << 4) >> 4;
                    self.set_reg(1, next_pc);
                    next_pc = self.pc.wrapping_add(imm as u32);
                }
                // C.LI
                0b010 => {
                    let rd = (inst >> 7) & 0x1f;
                    let imm = (((inst >> 12) & 1) << 5) | ((inst >> 2) & 0x1f);
                    let imm = ((imm as i16) << 10) >> 10;
                    if rd != 0 {
                        self.set_reg(rd, imm as u32);
                    }
                }
                // C.ADDI16SP / C.LUI
                0b011 => {
                    let rd = (inst >> 7) & 0x1f;
                    if rd == 2 {
                        let imm = (((inst >> 12) & 1) << 9)
                            | (((inst >> 3) & 3) << 7)
                            | (((inst >> 5) & 1) << 6)
                            | (((inst >> 2) & 1) << 5)
                            | (((inst >> 6) & 1) << 4);
                        let imm = ((imm as i16) << 6) >> 6;
                        self.set_reg(2, self.reg(2).wrapping_add(imm as u32));
                    } else if rd != 0 {
                        let imm = (((inst >> 12) & 1) << 17) | (((inst >> 2) & 0x1f) << 12);
                        let imm = ((imm as i32) << 14) >> 14;
                        self.set_reg(rd, imm as u32);
                    }
                }
                // C.SRLI / C.SRAI / C.ANDI / C.SUB / C.XOR / C.OR / C.AND
                0b100 => {
                    let rd = 8 + ((inst >> 7) & 0x7);
                    let bit10_11 = (inst >> 10) & 0x3;
                    let shamt = (((inst >> 12) & 1) << 5) | ((inst >> 2) & 0x1f);
                    match bit10_11 {
                        // C.SRLI
                        0b00 => {
                            self.set_reg(rd, self.reg(rd) >> shamt);
                        }
                        // C.SRAI
                        0b01 => {
                            let val = self.reg(rd) as i32;
                            self.set_reg(rd, (val >> shamt) as u32);
                        }
                        // C.ANDI
                        0b10 => {
                            let imm = (((inst >> 12) & 1) << 5) | ((inst >> 2) & 0x1f);
                            let imm = ((imm as i16) << 10) >> 10;
                            self.set_reg(rd, self.reg(rd) & (imm as u32));
                        }
                        // Arithmetic
                        0b11 => {
                            let rs2 = 8 + ((inst >> 2) & 0x7);
                            let bit12 = (inst >> 12) & 1;
                            let funct2 = (inst >> 5) & 0x3;
                            if bit12 == 0 {
                                match funct2 {
                                    0b00 => {
                                        self.set_reg(rd, self.reg(rd).wrapping_sub(self.reg(rs2)))
                                    } // C.SUB
                                    0b01 => self.set_reg(rd, self.reg(rd) ^ self.reg(rs2)), // C.XOR
                                    0b10 => self.set_reg(rd, self.reg(rd) | self.reg(rs2)), // C.OR
                                    0b11 => self.set_reg(rd, self.reg(rd) & self.reg(rs2)), // C.AND
                                    _ => {}
                                }
                            }
                        }
                        _ => {}
                    }
                }
                // C.J
                0b101 => {
                    let imm = (((inst >> 12) & 1) << 11)
                        | (((inst >> 8) & 1) << 10)
                        | (((inst >> 9) & 3) << 8)
                        | (((inst >> 6) & 1) << 7)
                        | (((inst >> 7) & 1) << 6)
                        | (((inst >> 2) & 1) << 5)
                        | (((inst >> 11) & 1) << 4)
                        | (((inst >> 3) & 7) << 1);
                    let imm = ((imm as i16) << 4) >> 4;
                    next_pc = self.pc.wrapping_add(imm as u32);
                }
                // C.BEQZ
                0b110 => {
                    let rs1 = 8 + ((inst >> 7) & 0x7);
                    if self.reg(rs1) == 0 {
                        let imm = (((inst >> 12) & 1) << 8)
                            | (((inst >> 5) & 3) << 6)
                            | (((inst >> 2) & 1) << 5)
                            | (((inst >> 10) & 3) << 3)
                            | (((inst >> 3) & 3) << 1);
                        let imm = ((imm as i16) << 7) >> 7;
                        next_pc = self.pc.wrapping_add(imm as u32);
                    }
                }
                // C.BNEZ
                0b111 => {
                    let rs1 = 8 + ((inst >> 7) & 0x7);
                    if self.reg(rs1) != 0 {
                        let imm = (((inst >> 12) & 1) << 8)
                            | (((inst >> 5) & 3) << 6)
                            | (((inst >> 2) & 1) << 5)
                            | (((inst >> 10) & 3) << 3)
                            | (((inst >> 3) & 3) << 1);
                        let imm = ((imm as i16) << 7) >> 7;
                        next_pc = self.pc.wrapping_add(imm as u32);
                    }
                }
                _ => {
                    self.fault = Some(format!(
                        "unsupported compressed instruction {inst:#06x} at {:#010x}",
                        self.pc
                    ))
                }
            },
            0b10 => match funct3 {
                // C.SLLI
                0b000 => {
                    let rd = (inst >> 7) & 0x1f;
                    let shamt = (((inst >> 12) & 1) << 5) | ((inst >> 2) & 0x1f);
                    if rd != 0 {
                        self.set_reg(rd, self.reg(rd) << shamt);
                    }
                }
                // C.LWSP
                0b010 => {
                    let rd = (inst >> 7) & 0x1f;
                    let imm = (((inst >> 2) & 3) << 6)
                        | (((inst >> 12) & 1) << 5)
                        | (((inst >> 4) & 7) << 2);
                    let addr = self.reg(2).wrapping_add(imm);
                    if rd != 0 {
                        self.set_reg(rd, bus.read_u32(addr));
                    }
                }
                // C.JR / C.MV / C.JALR / C.ADD
                0b100 => {
                    let bit12 = (inst >> 12) & 1;
                    let rd = (inst >> 7) & 0x1f;
                    let rs2 = (inst >> 2) & 0x1f;
                    if bit12 == 0 {
                        if rs2 == 0 {
                            // C.JR
                            next_pc = self.reg(rd) & !1;
                        } else {
                            // C.MV
                            self.set_reg(rd, self.reg(rs2));
                        }
                    } else {
                        if rs2 == 0 {
                            // C.JALR
                            let target = self.reg(rd) & !1;
                            self.set_reg(1, next_pc);
                            next_pc = target;
                        } else {
                            // C.ADD
                            self.set_reg(rd, self.reg(rd).wrapping_add(self.reg(rs2)));
                        }
                    }
                }
                // C.SWSP
                0b110 => {
                    let rs2 = (inst >> 2) & 0x1f;
                    let imm = (((inst >> 7) & 0x3) << 6) | (((inst >> 9) & 0xf) << 2);
                    let addr = self.reg(2).wrapping_add(imm);
                    bus.write_u32(addr, self.reg(rs2));
                }
                _ => {
                    self.fault = Some(format!(
                        "unsupported compressed instruction {inst:#06x} at {:#010x}",
                        self.pc
                    ))
                }
            },
            _ => {}
        }

        self.pc = next_pc;
    }

    fn read_csr(&self, csr: u32, bus: &Bus) -> u32 {
        match csr {
            0x001 => self.fcsr & 0x1f,
            0x002 => (self.fcsr >> 5) & 7,
            0x003 => self.fcsr & 0xff,
            0x300 => self.mstatus,
            0x304 => self.mie,
            0x305 => self.mtvec,
            0x307 => self.mtvt,
            0x340 => self.mscratch,
            0x341 => self.mepc,
            0x342 => self.mcause,
            0x343 => self.mtval,
            0x344 => self.mip,
            0xf14 => self.mhartid,
            0x301 => 0x4014_1125, // misa: RV32IMAFC
            0xb00 | 0xc00 => self.instructions_executed as u32, // mcycle / cycle
            0xb80 | 0xc80 => (self.instructions_executed >> 32) as u32,
            0xc01 => (bus.timer_ticks & 0xffff_ffff) as u32, // time
            _ => 0,
        }
    }

    fn write_csr(&mut self, csr: u32, val: u32) {
        match csr {
            0x001 => self.fcsr = (self.fcsr & !0x1f) | (val & 0x1f),
            0x002 => self.fcsr = (self.fcsr & !0xe0) | ((val & 7) << 5),
            0x003 => self.fcsr = val & 0xff,
            0x300 => self.mstatus = val,
            0x304 => self.mie = val,
            0x305 => self.mtvec = val,
            0x307 => self.mtvt = val & !0x3f,
            0x340 => self.mscratch = val,
            0x341 => self.mepc = val,
            0x342 => self.mcause = val,
            0x343 => self.mtval = val,
            0x344 => self.mip = val,
            _ => {}
        }
    }

    fn handle_rom_call(&mut self, bus: &mut Bus) {
        match self.pc {
            0x4fc0_0290 => {
                let start = u64::from(self.reg(10));
                let len = u64::from(self.reg(11));
                let valid = [
                    (0x3010_0000, 0x3010_2000),
                    (0x4800_0000, 0x4a00_0000),
                    (0x4ff0_0000, 0x5000_0000),
                    (0x5010_8000, 0x5011_0000),
                ]
                .iter()
                .any(|&(lo, hi)| {
                    start >= lo
                        && start + len <= hi
                        && !(bus.cache_l2_suspended && lo == 0x4800_0000)
                });
                if !valid || len > 1024 * 1024 || !bus.mapped_backing_range(start as u32, len) {
                    self.fault = Some("ROM bzero invalid range".into());
                    return;
                }
                for address in start..start + len {
                    bus.write_u8(address as u32, 0);
                }
                self.pc = self.reg(1);
            }
            0x4fc0_027c => {
                let (dest, src, count) = (self.reg(10), self.reg(11), self.reg(12));
                let start = u64::from(dest);
                let valid_dest = [
                    (0x3010_0000, 0x3010_2000),
                    (0x4800_0000, 0x4a00_0000),
                    (0x4ff0_0000, 0x5000_0000),
                    (0x5010_8000, 0x5011_0000),
                ]
                .iter()
                .any(|&(a, b)| {
                    start >= a
                        && start + u64::from(count) <= b
                        && !(bus.cache_l2_suspended && a == 0x4800_0000)
                });
                if count > 65536 || !valid_dest || !bus.mapped_backing_range(dest, u64::from(count))
                {
                    self.fault = Some("ROM strncpy invalid destination".into());
                    return;
                }
                let mut bytes = Vec::with_capacity(count as usize);
                let mut ended = false;
                for offset in 0..count {
                    if ended {
                        bytes.push(0);
                        continue;
                    }
                    let Some(address) = src.checked_add(offset) else {
                        self.fault = Some("ROM strncpy pointer overflow".into());
                        return;
                    };
                    if !super::rom_printf::readable(address, 1)
                        || !bus.mapped_backing_range(address, 1)
                    {
                        self.fault = Some("ROM strncpy invalid source".into());
                        return;
                    }
                    if u64::from(address) >= start && u64::from(address) < start + u64::from(count)
                    {
                        self.fault = Some("ROM strncpy overlapping ranges".into());
                        return;
                    }
                    let byte = bus.read_u8(address);
                    ended = byte == 0;
                    bytes.push(byte);
                }
                for (offset, byte) in bytes.into_iter().enumerate() {
                    bus.write_u8(dest + offset as u32, byte);
                }
                self.pc = self.reg(1);
            }
            #[cfg(test)]
            0x4fc0_014c | 0x4fc0_0154 | 0x4fc0_0158 | 0x4fc0_015c if bus.rom_flash.is_some() => {
                match super::rom_flash::call(bus, self.pc, self.reg(10), self.reg(11), self.reg(12))
                {
                    Ok(()) => {
                        self.set_reg(10, 0);
                        self.pc = self.reg(1);
                    }
                    Err(error) => self.fault = Some(format!("ROM flash fixture: {error}")),
                }
            }
            0x4fc0_0570 => {
                let (pin, signal, out_inv, enable_inv) =
                    (self.reg(10), self.reg(11), self.reg(12), self.reg(13));
                if pin > 56 || signal > 0x1ff || out_inv > 1 || enable_inv > 1 {
                    self.fault = Some("unsupported GPIO matrix output arguments".into());
                    return;
                }
                bus.write_u32(
                    0x500e_0558 + pin * 4,
                    signal | (out_inv << 9) | (enable_inv << 11),
                );
                let (register, bit) = if pin < 32 {
                    (0x500e_0024, pin)
                } else {
                    (0x500e_0030, pin - 32)
                };
                bus.write_u32(register, 1 << bit);
                self.pc = self.reg(1);
            }
            // rev0 ROM selects function 1 in the corresponding IO_MUX pad.
            0x4fc0_0590 => {
                let pin = self.reg(10);
                if pin <= 56 {
                    let address = 0x500e_1004 + pin * 4;
                    let value = bus.read_u32(address);
                    bus.write_u32(address, (value & !0x7000) | 0x1000);
                    self.set_reg(10, address);
                }
                self.pc = self.reg(1);
            }
            0x4fc0_0508 => {
                if bus.cache_l2_suspended || bus.cache_l2_mode.is_none() {
                    self.fault = Some("unsupported L2 cache suspend state".into());
                    return;
                }
                let autoload = u32::from(bus.cache_l2_autoload);
                let control = bus.read_u32(0x5008_c03c);
                bus.write_u32(0x5008_c03c, control | (1 << 31));
                bus.cache_l2_suspended = true;
                bus.cache_l2_autoload = false;
                self.set_reg(10, autoload);
                self.pc = self.reg(1);
            }
            0x4fc0_050c => {
                let autoload = self.reg(10);
                if !bus.cache_l2_suspended || autoload > 1 {
                    self.fault = Some("unsupported L2 cache resume state".into());
                    return;
                }
                let control = bus.read_u32(0x5008_c03c);
                bus.write_u32(0x5008_c03c, control & !(1 << 31));
                bus.cache_l2_suspended = false;
                bus.cache_l2_autoload = autoload != 0;
                self.pc = self.reg(1);
            }
            // Backing RAM is coherent in this functional model; no cache lines
            // or cache-suspension ordering are represented.
            0x4fc0_0414 => {
                if self.reg(10) != 16 {
                    self.fault = Some(format!(
                        "unsupported cache writeback map {:#x}",
                        self.reg(10)
                    ));
                    return;
                }
                self.set_reg(10, 0);
                self.pc = self.reg(1);
            }
            0x4fc0_033c => {
                let numerator = self.reg(10) as i32;
                let denominator = self.reg(11) as i32;
                if denominator == 0 || (numerator == i32::MIN && denominator == -1) {
                    self.fault = Some("ROM div unsupported operands".into());
                    return;
                }
                self.set_reg(10, (numerator / denominator) as u32);
                self.set_reg(11, (numerator % denominator) as u32);
                self.pc = self.reg(1);
            }
            0x4fc0_035c
                if bus.rom_execute
                    && bus.read_u16(0x4fc1_9746) == 0xbf65
                    && bus
                        .rom_executable
                        .iter()
                        .any(|&(a, b)| a <= 0x4fc1_96fe && b >= 0x4fc1_9748) =>
            {
                self.pc = 0x4fc1_9746;
            }
            0x4fc0_0374
                if bus.rom_execute
                    && bus.read_u32(0x4fc1_9436) == 0x1101_499c
                    && bus
                        .rom_executable
                        .iter()
                        .any(|&(a, b)| a <= 0x4fc1_9436 && b >= 0x4fc1_9490) =>
            {
                self.pc = 0x4fc1_9436;
            }
            0x4fc0_0270 => {
                let (dest, src, len) = (self.reg(10), self.reg(11), self.reg(12));
                let start = u64::from(dest);
                let size = u64::from(len);
                let dest_ok = [
                    (0x3010_0000, 0x3010_2000),
                    (0x4800_0000, 0x4a00_0000),
                    (0x4ff0_0000, 0x5000_0000),
                    (0x5010_8000, 0x5011_0000),
                ]
                .iter()
                .any(|&(lo, hi)| start >= lo && start + size <= hi);
                if len > 1024 * 1024
                    || !dest_ok
                    || !super::rom_printf::readable(src, len as usize)
                    || !bus.mapped_backing_range(dest, size)
                    || !bus.mapped_backing_range(src, size)
                {
                    self.fault = Some("ROM memmove invalid range".into());
                    return;
                }
                let bytes: Vec<_> = (0..len).map(|i| bus.read_u8(src + i)).collect();
                for (i, byte) in bytes.into_iter().enumerate() {
                    bus.write_u8(dest + i as u32, byte);
                }
                self.pc = self.reg(1);
            }
            0x4fc0_02dc => {
                let (start, byte, count) = (self.reg(10), self.reg(11) as u8, self.reg(12));
                if count > 1024 * 1024 {
                    self.fault = Some("ROM memchr exceeds limit".into());
                    return;
                }
                let mut result = 0;
                for offset in 0..count {
                    let Some(address) = start.checked_add(offset) else {
                        self.fault = Some("ROM memchr pointer overflow".into());
                        return;
                    };
                    if !super::rom_printf::readable(address, 1)
                        || !bus.mapped_backing_range(address, 1)
                    {
                        self.fault = Some("ROM memchr unmapped input".into());
                        return;
                    }
                    if bus.read_u8(address) == byte {
                        result = address;
                        break;
                    }
                }
                self.set_reg(10, result);
                self.pc = self.reg(1);
            }
            0x4fc0_0390
                if bus.rom_execute
                    && bus.read_u32(0x4fc1_b388) == 0xc422_1141
                    && bus
                        .rom_executable
                        .iter()
                        .any(|&(a, b)| a <= 0x4fc1_b388 && b >= 0x4fc1_b498) =>
            {
                self.pc = 0x4fc1_b388;
            }
            // These rev0 ROM functions only store/retrieve the guest pointer;
            // this does not implement guarded flash operations or callbacks.
            0x4fc0_01f0 => {
                bus.write_u32(0x4ff3_fff0, self.reg(10));
                self.pc = self.reg(1);
            }
            0x4fc0_01f4 => {
                self.set_reg(10, bus.read_u32(0x4ff3_fff0));
                self.pc = self.reg(1);
            }
            0x4fc0_0280 | 0x4fc0_0284 => {
                let strcmp = self.pc == 0x4fc0_0280;
                let (left, right) = (self.reg(10), self.reg(11));
                let count = if strcmp { 65536 } else { self.reg(12) };
                if count > 1024 * 1024 {
                    self.fault = Some("ROM strncmp exceeds limit".into());
                    return;
                }
                let mut result = 0i32;
                let mut finished = false;
                for offset in 0..count {
                    let (Some(a), Some(b)) = (left.checked_add(offset), right.checked_add(offset))
                    else {
                        self.fault = Some("ROM strncmp pointer overflow".into());
                        return;
                    };
                    if !super::rom_printf::readable(a, 1)
                        || !super::rom_printf::readable(b, 1)
                        || !bus.mapped_backing_range(a, 1)
                        || !bus.mapped_backing_range(b, 1)
                    {
                        self.fault = Some("ROM strncmp unmapped input".into());
                        return;
                    }
                    let (x, y) = (bus.read_u8(a), bus.read_u8(b));
                    if x != y {
                        result = i32::from(x) - i32::from(y);
                        finished = true;
                        break;
                    }
                    if x == 0 {
                        finished = true;
                        break;
                    }
                }
                if strcmp && !finished {
                    self.fault = Some("ROM strcmp exceeds limit".into());
                    return;
                }
                self.set_reg(10, result as u32);
                self.pc = self.reg(1);
            }
            0x4fc0_0278 => {
                let (dest, src) = (self.reg(10), self.reg(11));
                let value = match super::rom_printf::c_string(bus, src) {
                    Ok(value) => value,
                    Err(error) => {
                        self.fault = Some(format!("ROM strcpy: {error}"));
                        return;
                    }
                };
                let len = value.len() as u64 + 1;
                let start = u64::from(dest);
                let source = u64::from(src);
                let valid = [
                    (0x3010_0000, 0x3010_2000),
                    (0x4800_0000, 0x4a00_0000),
                    (0x4ff0_0000, 0x5000_0000),
                    (0x5010_8000, 0x5011_0000),
                ]
                .iter()
                .any(|&(lo, hi)| start >= lo && start + len <= hi);
                if !valid
                    || !bus.mapped_backing_range(dest, len)
                    || (start < source + len && source < start + len)
                {
                    self.fault = Some("ROM strcpy invalid or overlapping destination".into());
                    return;
                }
                for (offset, byte) in value.into_iter().chain([0]).enumerate() {
                    bus.write_u8(dest + offset as u32, byte);
                }
                self.pc = self.reg(1);
            }
            0x4fc0_0288 => match super::rom_printf::c_string(bus, self.reg(10)) {
                Ok(value) => {
                    self.set_reg(10, value.len() as u32);
                    self.pc = self.reg(1);
                }
                Err(error) => self.fault = Some(format!("ROM strlen: {error}")),
            },
            // ESP32-P4 rev0 ROM copies the two pointed-to lock values into
            // the ROM newlib recursive and ordinary lock objects, respectively.
            0x4fc0_0264 => {
                let (recursive, ordinary) = (self.reg(10), self.reg(11));
                let backed_word = |addr: u32| {
                    let start = u64::from(addr);
                    addr & 3 == 0
                        && [
                            (0x3010_0000, 0x3010_2000),
                            (0x4800_0000, 0x4a00_0000),
                            (0x4ff0_0000, 0x5000_0000),
                            (0x5010_8000, 0x5011_0000),
                        ]
                        .iter()
                        .any(|&(lo, hi)| start >= lo && start + 4 <= hi)
                };
                if !backed_word(recursive) || !backed_word(ordinary) {
                    self.fault = Some("invalid ROM newlib mutex pointer".into());
                    return;
                }
                let recursive_value = bus.read_u32(recursive);
                bus.write_u32(0x4ff3_ff8c, recursive_value);
                let ordinary_value = bus.read_u32(ordinary);
                bus.write_u32(0x4ff3_ff88, ordinary_value);
                self.pc = self.reg(1);
            }
            0x4fc0_0234 => match super::rom_systimer::counter(bus, self.reg(10), self.reg(11)) {
                Ok(value) => {
                    self.set_reg(10, value as u32);
                    self.set_reg(11, (value >> 32) as u32);
                    self.pc = self.reg(1);
                }
                Err(error) => self.fault = Some(format!("ROM systimer: {error}")),
            },
            0x4fc0_0254 | 0x4fc0_0258 | 0x4fc0_025c | 0x4fc0_0260 => {
                match super::rom_systimer::call(
                    bus,
                    self.pc,
                    self.reg(10),
                    self.reg(11),
                    self.reg(12),
                    self.reg(13),
                ) {
                    Ok(()) => self.pc = self.reg(1),
                    Err(error) => self.fault = Some(format!("ROM systimer: {error}")),
                }
            }
            // systimer HAL stores the two guest callbacks in the context;
            // subsequent timer APIs must actually invoke them when needed.
            0x4fc0_0230 => {
                let (ctx, ops) = (self.reg(10), self.reg(11));
                let ram = |addr: u32, len: u64| {
                    let start = u64::from(addr);
                    [
                        (0x3010_0000, 0x3010_2000),
                        (0x4800_0000, 0x4a00_0000),
                        (0x4ff0_0000, 0x5000_0000),
                        (0x5010_8000, 0x5011_0000),
                    ]
                    .iter()
                    .any(|&(a, b)| start >= a && start + len <= b)
                };
                if ctx & 3 != 0 || ops & 3 != 0 || !ram(ctx, 12) || !ram(ops, 8) {
                    self.fault = Some("invalid systimer context or callbacks pointer".into());
                    return;
                }
                let first = bus.read_u32(ops);
                let second = bus.read_u32(ops + 4);
                let executable = |p: u32| {
                    p & 1 == 0
                        && [
                            (0x3010_0000, 0x3010_2000),
                            (0x4000_0000, 0x4100_0000),
                            (0x4ff0_0000, 0x5000_0000),
                        ]
                        .iter()
                        .any(|&(a, b)| p >= a && p < b)
                };
                if !executable(first) || !executable(second) {
                    self.fault = Some("unsupported systimer callback address".into());
                    return;
                }
                bus.write_u32(ctx + 4, first);
                bus.write_u32(ctx + 8, second);
                self.pc = self.reg(1);
            }
            // libgcc ffs: 1-based least-significant set bit, zero for zero.
            0x4fc0_07a0 => {
                let value = self.reg(10);
                self.set_reg(
                    10,
                    if value == 0 {
                        0
                    } else {
                        value.trailing_zeros() + 1
                    },
                );
                self.pc = self.reg(1);
            }
            // rev0/rev1 libgcc helper; zero returns 32 in this ROM table.
            0x4fc0_0770 => {
                self.set_reg(10, self.reg(10).leading_zeros());
                self.pc = self.reg(1);
            }
            0x4fc0_0348 => {
                if let Err(error) = super::rom_qsort::begin(self, bus) {
                    self.fault = Some(format!("ROM qsort: {error}"));
                }
            }
            // rev0/rev1 ROM writes priority into the selected CLIC control byte.
            0x4fc0_05b8 => {
                let (line, priority) = (self.reg(10), self.reg(11));
                if line >= 32 || priority >= 8 {
                    self.fault = Some(format!(
                        "unsupported interrupt priority line={line} priority={priority}"
                    ));
                    return;
                }
                bus.write_u8(0x2080_1043 + 4 * line, (priority << 5) as u8);
                self.pc = self.reg(1);
            }
            // rev0/rev1 ROM routes source to CLIC interrupt number + 16.
            0x4fc0_05d0 => {
                let (hart, source, line) = (self.reg(10), self.reg(11), self.reg(12));
                if hart > 1 || source >= 136 || line >= 32 {
                    self.fault = Some(format!(
                        "unsupported interrupt route hart={hart} source={source} line={line}"
                    ));
                    return;
                }
                bus.write_u32(0x500d_6000 + hart * 0x800 + source * 4, line + 16);
                self.pc = self.reg(1);
            }
            // rev0/rev1 ROM maps bit n to CLIC interrupt n+16 enable byte.
            0x4fc0_05c0 | 0x4fc0_05c4 => {
                let enabled = u8::from(self.pc == 0x4fc0_05c0);
                let mask = self.reg(10);
                for bit in 0..32 {
                    if mask & (1 << bit) != 0 {
                        bus.write_u8(0x2080_1041 + 4 * bit, enabled);
                    }
                }
                self.pc = self.reg(1);
            }
            // ROM serial port 6 is USB Serial/JTAG. This fixture appends output
            // synchronously, so there is no pending transmit queue to drain.
            0x4fc0_0078 => {
                if self.reg(10) != 6 {
                    self.fault = Some(format!("unsupported ROM console port {}", self.reg(10)));
                    return;
                }
                self.pc = self.reg(1);
            }
            0x4fc0_0204 | 0x4fc0_0208 | 0x4fc0_020c | 0x4fc0_0214 | 0x4fc0_021c => {
                match super::rom_wdt::call(
                    bus,
                    self.pc,
                    self.reg(10),
                    self.reg(11),
                    self.reg(12),
                    self.reg(13),
                ) {
                    Ok(()) => self.pc = self.reg(1),
                    Err(error) => self.fault = Some(format!("ROM watchdog: {error}")),
                }
            }
            // RV32 ABI passes and returns 64-bit integers in low/high pairs.
            0x4fc0_0844 | 0x4fc0_0854 => {
                let dividend = u64::from(self.reg(10)) | (u64::from(self.reg(11)) << 32);
                let divisor = u64::from(self.reg(12)) | (u64::from(self.reg(13)) << 32);
                if divisor == 0 {
                    self.fault = Some("ROM unsigned 64-bit division by zero".into());
                    return;
                }
                let result = if self.pc == 0x4fc0_0844 {
                    dividend / divisor
                } else {
                    dividend % divisor
                };
                self.set_reg(10, result as u32);
                self.set_reg(11, (result >> 32) as u32);
                self.pc = self.reg(1);
            }
            // P4 PSRAM IDF fixture: MSPI3 in OPI DTR mode. Command setup and
            // execution remain separate ROM calls and fail until modeled.
            0x4fc0_0110 => {
                let mode = (self.reg(10), self.reg(11));
                bus.rom_psram_command = None;
                bus.rom_spi_mode = None;
                if mode != (3, 7) {
                    self.fault = Some(format!("unsupported ROM SPI mode {mode:?}"));
                    return;
                }
                bus.rom_spi_mode = Some(mode);
                self.pc = self.reg(1);
            }
            0x4fc0_0108 => match super::rom_psram::configure(bus, self.reg(10), self.reg(11)) {
                Ok(()) => self.pc = self.reg(1),
                Err(error) => self.fault = Some(format!("ROM PSRAM config: {error}")),
            },
            0x4fc0_010c => match super::rom_psram::start(
                bus,
                self.reg(10),
                self.reg(11),
                self.reg(12),
                self.reg(13),
                self.reg(14),
            ) {
                Ok(()) => self.pc = self.reg(1),
                Err(error) => self.fault = Some(format!("ROM PSRAM start: {error}")),
            },
            // Format into a temporary buffer so invalid guest pointers/formats
            // cannot produce misleading partial output.
            0x4fc0_0024 => match super::rom_printf::format(self, bus) {
                Ok(output) => {
                    self.set_reg(10, output.len() as u32);
                    bus.console_output.extend_from_slice(&output);
                    self.pc = self.reg(1);
                }
                Err(error) => self.fault = Some(format!("unsupported ROM printf: {error}")),
            },
            // Advance the same functional clock used by the timer model, not
            // host wall-clock time. Large delays are deliberately bounded.
            0x4fc0_003c => {
                let micros = self.reg(10);
                if micros > 1_000_000 {
                    self.fault = Some(format!("ROM delay too large: {micros} us"));
                    return;
                }
                bus.timer_ticks = bus.timer_ticks.wrapping_add(u64::from(micros) * 360);
                self.pc = self.reg(1);
            }
            // rtc_get_reset_reason: this fixture currently models a power-on reset.
            0x4fc0_0018 => {
                self.set_reg(10, 1);
                self.pc = self.reg(1);
            }
            // ROM memset: allow only backed RAM, never MMIO or wrapped ranges.
            0x4fc0_0268 => {
                let start = self.reg(10) as u64;
                let end = start + self.reg(12) as u64;
                let in_ram = [
                    (0x3010_0000, 0x3010_2000),
                    (0x4800_0000, 0x4a00_0000),
                    (0x4ff0_0000, 0x5000_0000),
                    (0x5010_8000, 0x5011_0000),
                ]
                .iter()
                .any(|&(a, b)| start >= a && end <= b);
                if !in_ram || !bus.mapped_backing_range(start as u32, end - start) {
                    self.fault = Some(format!(
                        "ROM memset outside RAM: {start:#010x}..{end:#010x}"
                    ));
                    return;
                }
                for address in start..end {
                    bus.write_u8(address as u32, self.reg(11) as u8);
                }
                self.pc = self.reg(1);
            }
            // ROM memcpy: retain source/destination and reject MMIO or overlap.
            0x4fc0_026c => {
                let dest = self.reg(10) as u64;
                let src = self.reg(11) as u64;
                let len = self.reg(12) as u64;
                let ram = [
                    (0x3010_0000, 0x3010_2000),
                    (0x4800_0000, 0x4a00_0000),
                    (0x4ff0_0000, 0x5000_0000),
                    (0x5010_8000, 0x5011_0000),
                ];
                let dest_ok = ram.iter().any(|&(a, b)| dest >= a && dest + len <= b);
                let src_ok = ram
                    .iter()
                    .chain([(0x4000_0000, 0x4100_0000)].iter())
                    .any(|&(a, b)| src >= a && src + len <= b);
                if !dest_ok
                    || !src_ok
                    || !bus.mapped_backing_range(dest as u32, len)
                    || !bus.mapped_backing_range(src as u32, len)
                    || (len != 0 && dest < src + len && src < dest + len)
                {
                    self.fault = Some(format!(
                        "ROM memcpy unsupported: dst={dest:#010x} src={src:#010x} len={len}"
                    ));
                    return;
                }
                for offset in 0..len {
                    let value = bus.read_u8((src + offset) as u32);
                    bus.write_u8((dest + offset) as u32, value);
                }
                self.pc = self.reg(1);
            }
            0x4fc0_0274 => {
                let left = self.reg(10) as u64;
                let right = self.reg(11) as u64;
                let len = self.reg(12) as u64;
                let regions = [
                    (0x3010_0000, 0x3010_2000),
                    (0x4000_0000, 0x4100_0000),
                    (0x4800_0000, 0x4a00_0000),
                    (0x4ff0_0000, 0x5000_0000),
                    (0x5010_8000, 0x5011_0000),
                ];
                let valid =
                    |start: u64| regions.iter().any(|&(a, b)| start >= a && start + len <= b);
                if len > 1024 * 1024
                    || !valid(left)
                    || !valid(right)
                    || !bus.mapped_backing_range(left as u32, len)
                    || !bus.mapped_backing_range(right as u32, len)
                {
                    self.fault = Some(format!(
                        "ROM memcmp unsupported: left={left:#010x} right={right:#010x} len={len}"
                    ));
                    return;
                }
                let mut difference = 0i32;
                for offset in 0..len {
                    difference = i32::from(bus.read_u8((left + offset) as u32))
                        - i32::from(bus.read_u8((right + offset) as u32));
                    if difference != 0 {
                        break;
                    }
                }
                self.set_reg(10, difference as u32);
                self.pc = self.reg(1);
            }
            // IDF 5.4 P4 cache_hal_init_l2_cache profile. The bus is coherent;
            // this tracks configuration, not real cache contents or timing.
            0x4fc0_03d4 => {
                let mode = (self.reg(10), self.reg(11), self.reg(12));
                if mode != (9, 8, 3) {
                    self.fault = Some(format!("unsupported L2 cache mode {mode:?}"));
                    return;
                }
                bus.cache_l2_mode = Some(mode);
                self.pc = self.reg(1);
            }
            // Cache_Invalidate_All(CACHE_MAP_L2_CACHE), after the above setup.
            0x4fc0_0404 => {
                if self.reg(10) != 32 || bus.cache_l2_mode.is_none() {
                    self.fault = Some(format!(
                        "unsupported cache invalidate map {:#x}",
                        self.reg(10)
                    ));
                    return;
                }
                bus.cache_l2_invalidations = bus.cache_l2_invalidations.saturating_add(1);
                self.set_reg(10, 0);
                self.pc = self.reg(1);
            }
            // nih_rom_putc
            0x4fc0_0054 => {
                let ch = self.reg(10) as u8; // a0
                bus.console_output.push(ch);
                self.pc = self.reg(1);
            }
            // ets_get_cpu_frequency / nih_rom_get_cpu_ticks (ticks per us).
            0x4fc0_0040 => {
                self.set_reg(10, bus.rom_cpu_mhz);
                self.pc = self.reg(1);
            }
            // ets_update_cpu_frequency / nih_rom_set_cpu_ticks.
            0x4fc0_0044 => {
                bus.rom_cpu_mhz = self.reg(10);
                self.pc = self.reg(1);
            }
            // nih_rom_set_cpu1_entry
            0x4fc0_00a8 => {
                if self.mhartid == 0 && self.reg(10) != 0 {
                    bus.cpu1_entry = Some(self.reg(10));
                }
                self.set_reg(10, 0);
                self.pc = self.reg(1);
            }
            // nih_rom_l2_line_size
            0x4fc0_03cc => {
                self.set_reg(10, 64);
                self.pc = self.reg(1);
            }
            // nih_rom_cache_invalidate / writeback / l2_enable
            0x4fc0_03e4 | 0x4fc0_03f4 | 0x4fc0_0504 => {
                self.set_reg(10, 0);
                self.pc = self.reg(1);
            }
            _ => {
                self.fault = Some(format!("unsupported ROM call at {:#010x}", self.pc));
            }
        }
    }
}
