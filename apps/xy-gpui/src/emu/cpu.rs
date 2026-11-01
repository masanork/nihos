//! RV32IMAFC CPU emulator for nihos firmware execution.

use super::bus::Bus;

pub struct Cpu {
    pub x: [u32; 32],
    pub f: [f32; 32],
    pub pc: u32,

    // CSRs
    pub mstatus: u32,
    pub mie: u32,
    pub mtvec: u32,
    pub mscratch: u32,
    pub mepc: u32,
    pub mcause: u32,
    pub mtval: u32,
    pub mip: u32,
    pub mhartid: u32,

    pub instructions_executed: u64,
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
            mscratch: 0,
            mepc: 0,
            mcause: 0,
            mtval: 0,
            mip: 0,
            mhartid: 0,
            instructions_executed: 0,
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

    pub fn step(&mut self, bus: &mut Bus) -> bool {
        // Handle timer ticks periodically
        if self.instructions_executed & 0xff == 0 {
            bus.timer_ticks = bus.timer_ticks.wrapping_add(256);
        }

        // ROM Call HLE Dispatch (0x4fc0_0000..=0x4fc0_ffff)
        if (0x4fc0_0000..=0x4fc0_ffff).contains(&self.pc) {
            self.handle_rom_call(bus);
            self.instructions_executed += 1;
            return true;
        }

        // Fetch instruction (support 16-bit compressed or 32-bit standard)
        let raw16 = bus.read_u16(self.pc);
        if (raw16 & 0x03) != 0x03 {
            // Compressed 16-bit instruction (RVC)
            self.execute_c(raw16, bus);
            self.instructions_executed += 1;
            return true;
        }

        let inst = bus.read_u32(self.pc);
        self.execute_32(inst, bus);
        self.instructions_executed += 1;
        true
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
                    0x0 => v1 == v2,                      // BEQ
                    0x1 => v1 != v2,                      // BNE
                    0x4 => (v1 as i32) < (v2 as i32),     // BLT
                    0x5 => (v1 as i32) >= (v2 as i32),    // BGE
                    0x6 => v1 < v2,                       // BLTU
                    0x7 => v1 >= v2,                      // BGEU
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
                    0x0 => (bus.read_u8(addr) as i8 as i32) as u32,    // LB
                    0x1 => (bus.read_u16(addr) as i16 as i32) as u32,  // LH
                    0x2 => bus.read_u32(addr),                         // LW
                    0x4 => bus.read_u8(addr) as u32,                   // LBU
                    0x5 => bus.read_u16(addr) as u32,                  // LHU
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
                    0x0 => v.wrapping_add(imm),                        // ADDI
                    0x1 => v << shamt,                                 // SLLI
                    0x2 => if (v as i32) < (imm as i32) { 1 } else { 0 }, // SLTI
                    0x3 => if v < imm { 1 } else { 0 },                // SLTIU
                    0x4 => v ^ imm,                                    // XORI
                    0x5 => if (funct7 & 0x20) != 0 {
                        ((v as i32) >> shamt) as u32                   // SRAI
                    } else {
                        v >> shamt                                     // SRLI
                    },
                    0x6 => v | imm,                                    // ORI
                    0x7 => v & imm,                                    // ANDI
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
                        0x0 => v1.wrapping_mul(v2),                       // MUL
                        0x1 => (((v1 as i32 as i64) * (v2 as i32 as i64)) >> 32) as u32, // MULH
                        0x2 => (((v1 as i32 as i64) * (v2 as u64 as i64)) >> 32) as u32, // MULHSU
                        0x3 => (((v1 as u64) * (v2 as u64)) >> 32) as u32, // MULHU
                        0x4 => if v2 == 0 { u32::MAX } else { ((v1 as i32).wrapping_div(v2 as i32)) as u32 }, // DIV
                        0x5 => if v2 == 0 { u32::MAX } else { v1 / v2 },  // DIVU
                        0x6 => if v2 == 0 { v1 } else { ((v1 as i32).wrapping_rem(v2 as i32)) as u32 },       // REM
                        0x7 => if v2 == 0 { v1 } else { v1 % v2 },        // REMU
                        _ => 0,
                    };
                    self.set_reg(rd, res);
                } else {
                    let shamt = v2 & 0x1f;
                    let res = match funct3 {
                        0x0 => if (funct7 & 0x20) != 0 { v1.wrapping_sub(v2) } else { v1.wrapping_add(v2) }, // SUB / ADD
                        0x1 => v1 << shamt,                            // SLL
                        0x2 => if (v1 as i32) < (v2 as i32) { 1 } else { 0 }, // SLT
                        0x3 => if v1 < v2 { 1 } else { 0 },            // SLTU
                        0x4 => v1 ^ v2,                                // XOR
                        0x5 => if (funct7 & 0x20) != 0 {
                            ((v1 as i32) >> shamt) as u32              // SRA
                        } else {
                            v1 >> shamt                                // SRL
                        },
                        0x6 => v1 | v2,                                // OR
                        0x7 => v1 & v2,                                // AND
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
                    0x00 => { // AMOADD.W
                        let val = orig.wrapping_add(v2);
                        bus.write_u32(addr, val);
                        orig
                    }
                    0x01 => { // AMOSWAP.W
                        bus.write_u32(addr, v2);
                        orig
                    }
                    0x02 => { // LR.W
                        orig
                    }
                    0x03 => { // SC.W
                        bus.write_u32(addr, v2);
                        0 // success
                    }
                    0x04 => { // AMOXOR.W
                        bus.write_u32(addr, orig ^ v2);
                        orig
                    }
                    0x08 => { // AMOOR.W
                        bus.write_u32(addr, orig | v2);
                        orig
                    }
                    0x0c => { // AMOAND.W
                        bus.write_u32(addr, orig & v2);
                        orig
                    }
                    0x10 => { // AMOMIN.W
                        let min_val = if (orig as i32) < (v2 as i32) { orig } else { v2 };
                        bus.write_u32(addr, min_val);
                        orig
                    }
                    0x14 => { // AMOMAX.W
                        let max_val = if (orig as i32) > (v2 as i32) { orig } else { v2 };
                        bus.write_u32(addr, max_val);
                        orig
                    }
                    0x18 => { // AMOMINU.W
                        let min_val = if orig < v2 { orig } else { v2 };
                        bus.write_u32(addr, min_val);
                        orig
                    }
                    0x1c => { // AMOMAXU.W
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
                    let operand = if (funct3 & 0x04) != 0 { rs1 } else { self.reg(rs1) };
                    let new_val = match funct3 & 0x03 {
                        0x1 => operand,                       // CSRRW
                        0x2 => old_val | operand,             // CSRRS
                        0x3 => old_val & !operand,            // CSRRC
                        _ => old_val,
                    };
                    self.write_csr(csr, new_val);
                    self.set_reg(rd, old_val);
                }
            }
            _ => {}
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
                    if imm != 0 {
                        self.set_reg(rd, self.reg(2).wrapping_add(imm as u32));
                    }
                }
                // C.LW
                0b010 => {
                    let imm = (((inst >> 5) & 0x1) << 6)
                        | (((inst >> 10) & 0x7) << 3)
                        | (((inst >> 6) & 0x1) << 2);
                    let rs1 = 8 + ((inst >> 7) & 0x7);
                    let rd = 8 + ((inst >> 2) & 0x7);
                    let addr = self.reg(rs1).wrapping_add(imm as u32);
                    self.set_reg(rd, bus.read_u32(addr));
                }
                // C.SW
                0b110 => {
                    let imm = (((inst >> 5) & 0x1) << 6)
                        | (((inst >> 10) & 0x7) << 3)
                        | (((inst >> 6) & 0x1) << 2);
                    let rs1 = 8 + ((inst >> 7) & 0x7);
                    let rs2 = 8 + ((inst >> 2) & 0x7);
                    let addr = self.reg(rs1).wrapping_add(imm as u32);
                    bus.write_u32(addr, self.reg(rs2));
                }
                _ => {}
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
                                    0b00 => self.set_reg(rd, self.reg(rd).wrapping_sub(self.reg(rs2))), // C.SUB
                                    0b01 => self.set_reg(rd, self.reg(rd) ^ self.reg(rs2)),            // C.XOR
                                    0b10 => self.set_reg(rd, self.reg(rd) | self.reg(rs2)),            // C.OR
                                    0b11 => self.set_reg(rd, self.reg(rd) & self.reg(rs2)),            // C.AND
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
                _ => {}
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
                    let imm = (((inst >> 2) & 3) << 6) | (((inst >> 12) & 1) << 5) | (((inst >> 4) & 7) << 2);
                    let addr = self.reg(2).wrapping_add(imm as u32);
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
                    let addr = self.reg(2).wrapping_add(imm as u32);
                    bus.write_u32(addr, self.reg(rs2));
                }
                _ => {}
            },
            _ => {}
        }

        self.pc = next_pc;
    }

    fn read_csr(&self, csr: u32, bus: &Bus) -> u32 {
        match csr {
            0x300 => self.mstatus,
            0x304 => self.mie,
            0x305 => self.mtvec,
            0x340 => self.mscratch,
            0x341 => self.mepc,
            0x342 => self.mcause,
            0x343 => self.mtval,
            0x344 => self.mip,
            0xf14 => self.mhartid,
            0x301 => 0x4014_1125, // misa: RV32IMAFC
            0xc00 => (self.instructions_executed & 0xffff_ffff) as u32, // cycle
            0xc01 => (bus.timer_ticks & 0xffff_ffff) as u32,            // time
            _ => 0,
        }
    }

    fn write_csr(&mut self, csr: u32, val: u32) {
        match csr {
            0x300 => self.mstatus = val,
            0x304 => self.mie = val,
            0x305 => self.mtvec = val,
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
            // nih_rom_putc
            0x4fc0_0054 => {
                let ch = self.reg(10) as u8; // a0
                bus.console_output.push(ch);
                self.pc = self.reg(1);
            }
            // nih_rom_get_cpu_ticks
            0x4fc0_0040 => {
                self.set_reg(10, bus.timer_ticks as u32);
                self.pc = self.reg(1);
            }
            // nih_rom_set_cpu_ticks
            0x4fc0_0044 => {
                bus.timer_ticks = self.reg(10) as u64;
                self.pc = self.reg(1);
            }
            // nih_rom_set_cpu1_entry
            0x4fc0_00a8 => {
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
                self.pc = self.reg(1);
            }
        }
    }
}
