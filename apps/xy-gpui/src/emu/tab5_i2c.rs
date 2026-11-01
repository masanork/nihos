//! Minimal Tab5 boot bus: GPIO open-drain wires, IO expander and touch ID.
//! Models line-level I2C so either firmware or a hardware controller can use it.

#[derive(Clone, Copy, Debug)]
enum Next {
    Receive,
    Send,
    Ignore,
}
#[derive(Clone, Copy, Debug)]
enum Phase {
    Idle,
    Receive {
        byte: u8,
        bits: u8,
    },
    Ack {
        accept: bool,
        armed: bool,
        clocked: bool,
        next: Next,
    },
    Send {
        byte: u8,
        bits: u8,
    },
    MasterAck {
        armed: bool,
        clocked: bool,
        accepted: bool,
    },
    Ignore,
}

pub struct Tab5I2c {
    scl: bool,
    sda: bool,
    slave_low: bool,
    phase: Phase,
    address_phase: bool,
    device: u8,
    reg: u8,
    expect_reg: bool,
    expander: [u8; 256],
}
impl Default for Tab5I2c {
    fn default() -> Self {
        let mut expander = [0; 256];
        expander[1] = 0xa1;
        Self {
            scl: true,
            sda: true,
            slave_low: false,
            phase: Phase::Idle,
            address_phase: true,
            device: 0,
            reg: 0,
            expect_reg: true,
            expander,
        }
    }
}
impl Tab5I2c {
    pub fn data_high(&self) -> bool {
        self.sda && !self.slave_low
    }
    pub fn clock_high(&self) -> bool {
        self.scl
    }
    fn read_data(&mut self) -> u8 {
        let value = match self.device {
            0x43 => self.expander[self.reg as usize],
            0x55 => 3,
            _ => 0xff,
        };
        self.reg = self.reg.wrapping_add(1);
        value
    }
    fn receive(&mut self, byte: u8) -> (bool, Next) {
        if self.address_phase {
            self.address_phase = false;
            self.device = byte >> 1;
            let accepted = self.device == 0x43 || self.device == 0x55;
            if byte & 1 == 0 {
                self.expect_reg = true;
            }
            return (
                accepted,
                if !accepted {
                    Next::Ignore
                } else if byte & 1 != 0 {
                    Next::Send
                } else {
                    Next::Receive
                },
            );
        }
        if self.expect_reg {
            self.reg = byte;
            self.expect_reg = false;
        } else if self.device == 0x43 {
            self.expander[self.reg as usize] = byte;
            self.reg = self.reg.wrapping_add(1);
        }
        (true, Next::Receive)
    }
    fn send_bit(&mut self, byte: u8, bits: u8) {
        self.slave_low = byte & (0x80 >> bits) == 0;
    }
    pub fn set_lines(&mut self, scl: bool, sda: bool) {
        let old_scl = self.scl;
        let old_sda = self.sda;
        self.scl = scl;
        self.sda = sda;
        if old_scl && scl && old_sda != sda {
            self.slave_low = false;
            if !sda {
                self.phase = Phase::Receive { byte: 0, bits: 0 };
                self.address_phase = true;
            } else {
                self.phase = Phase::Idle;
            }
            return;
        }
        if !old_scl && scl {
            self.phase = match self.phase {
                Phase::Receive { byte, bits } => {
                    let byte = (byte << 1) | u8::from(sda);
                    if bits == 7 {
                        let (accept, next) = self.receive(byte);
                        Phase::Ack {
                            accept,
                            armed: false,
                            clocked: false,
                            next,
                        }
                    } else {
                        Phase::Receive {
                            byte,
                            bits: bits + 1,
                        }
                    }
                }
                Phase::Ack {
                    accept,
                    armed,
                    next,
                    ..
                } if armed => Phase::Ack {
                    accept,
                    armed,
                    clocked: true,
                    next,
                },
                Phase::Send { byte, bits } => Phase::Send {
                    byte,
                    bits: bits + 1,
                },
                Phase::MasterAck { armed, .. } if armed => Phase::MasterAck {
                    armed,
                    clocked: true,
                    accepted: !sda,
                },
                phase => phase,
            };
        } else if old_scl && !scl {
            self.phase = match self.phase {
                Phase::Ack {
                    accept,
                    armed: false,
                    next,
                    ..
                } => {
                    self.slave_low = accept;
                    Phase::Ack {
                        accept,
                        armed: true,
                        clocked: false,
                        next,
                    }
                }
                Phase::Ack {
                    clocked: true,
                    next,
                    ..
                } => {
                    self.slave_low = false;
                    match next {
                        Next::Receive => Phase::Receive { byte: 0, bits: 0 },
                        Next::Ignore => Phase::Ignore,
                        Next::Send => {
                            let byte = self.read_data();
                            self.send_bit(byte, 0);
                            Phase::Send { byte, bits: 0 }
                        }
                    }
                }
                Phase::Send { byte: _, bits: 8 } => {
                    self.slave_low = false;
                    Phase::MasterAck {
                        armed: true,
                        clocked: false,
                        accepted: false,
                    }
                }
                Phase::Send { byte, bits } => {
                    self.send_bit(byte, bits);
                    Phase::Send { byte, bits }
                }
                Phase::MasterAck {
                    clocked: true,
                    accepted,
                    ..
                } => {
                    if accepted {
                        let byte = self.read_data();
                        self.send_bit(byte, 0);
                        Phase::Send { byte, bits: 0 }
                    } else {
                        Phase::Ignore
                    }
                }
                phase => phase,
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn start(bus: &mut Tab5I2c) {
        bus.set_lines(true, true);
        bus.set_lines(true, false);
        bus.set_lines(false, false);
    }
    fn stop(bus: &mut Tab5I2c) {
        bus.set_lines(false, false);
        bus.set_lines(true, false);
        bus.set_lines(true, true);
    }
    fn write(bus: &mut Tab5I2c, b: u8) -> bool {
        for bit in (0..8).rev() {
            let high = b & (1 << bit) != 0;
            bus.set_lines(false, high);
            bus.set_lines(true, high);
            bus.set_lines(false, high);
        }
        bus.set_lines(false, true);
        bus.set_lines(true, true);
        let ack = !bus.data_high();
        bus.set_lines(false, true);
        ack
    }
    fn read_last(bus: &mut Tab5I2c) -> u8 {
        let mut value = 0;
        for _ in 0..8 {
            bus.set_lines(false, true);
            bus.set_lines(true, true);
            value = (value << 1) | u8::from(bus.data_high());
            bus.set_lines(false, true);
        }
        bus.set_lines(false, true);
        bus.set_lines(true, true);
        bus.set_lines(false, true);
        value
    }
    #[test]
    fn expander_round_trip_and_repeated_start() {
        let mut bus = Tab5I2c::default();
        start(&mut bus);
        assert!(write(&mut bus, 0x86));
        assert!(write(&mut bus, 5));
        assert!(write(&mut bus, 0x35));
        stop(&mut bus);
        start(&mut bus);
        assert!(write(&mut bus, 0x86));
        assert!(write(&mut bus, 5));
        start(&mut bus);
        assert!(write(&mut bus, 0x87));
        assert_eq!(read_last(&mut bus), 0x35);
        stop(&mut bus);
        start(&mut bus);
        assert!(!write(&mut bus, 0x80));
        stop(&mut bus);
    }
}
