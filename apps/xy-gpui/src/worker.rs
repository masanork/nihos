//! Own the guest on a dedicated thread; the UI exchanges commands and latest frames.
use crate::emu::{self, Emulator};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
    mpsc,
};

struct Snapshot {
    frame: Option<Arc<Vec<u8>>>,
    revision: u64,
    error: Option<String>,
    #[cfg(test)]
    steps: u64,
    #[cfg(test)]
    ready: bool,
}

fn publish(emu: &Emulator, shared: &Mutex<Snapshot>) {
    let mut bgra = vec![0; emu::bus::FB_WIDTH * emu::bus::FB_HEIGHT * 4];
    emu.render_to_bgra(&mut bgra);
    let mut state = shared.lock().unwrap();
    state.frame = Some(Arc::new(bgra));
    state.revision = state.revision.wrapping_add(1);
}

enum Command {
    Key(u8),
    Paste(Vec<u8>),
    Arrow(String),
    Touch(Option<(u16, u16)>),
    Pause(bool),
    PowerOff,
    Reset { resume: bool },
    Frame,
}

pub struct Worker {
    tx: mpsc::Sender<Command>,
    snapshot: Arc<Mutex<Snapshot>>,
    frame_pending: Arc<AtomicBool>,
    pending_control: Arc<AtomicUsize>,
    pub paused: bool,
}

impl Worker {
    pub fn new(mut emu: Emulator) -> Self {
        let (tx, rx) = mpsc::channel();
        let snapshot = Arc::new(Mutex::new(Snapshot {
            frame: None,
            revision: 0,
            error: None,
            #[cfg(test)]
            steps: 0,
            #[cfg(test)]
            ready: false,
        }));
        let frame_pending = Arc::new(AtomicBool::new(false));
        let pending_control = Arc::new(AtomicUsize::new(0));
        let controls = Arc::clone(&pending_control);
        let shared = Arc::clone(&snapshot);
        let pending = Arc::clone(&frame_pending);
        std::thread::spawn(move || {
            let mut powered = true;
            let mut last_revision = None;
            loop {
                let command = if powered && !emu.paused {
                    match rx.try_recv() {
                        Ok(command) => Some(command),
                        Err(mpsc::TryRecvError::Empty) => None,
                        Err(mpsc::TryRecvError::Disconnected) => break,
                    }
                } else {
                    match rx.recv() {
                        Ok(command) => Some(command),
                        Err(_) => break,
                    }
                };
                match command {
                    Some(Command::Key(key)) if powered && !emu.paused => emu.send_key(key),
                    Some(Command::Paste(bytes)) if powered && !emu.paused => {
                        for byte in bytes {
                            emu.send_key(byte);
                        }
                    }
                    Some(Command::Arrow(key)) if powered && !emu.paused => {
                        crate::send_emulator_arrow(&mut emu, &key);
                    }
                    Some(Command::Touch(point)) => emu.bus.touch(point),
                    Some(Command::Pause(paused)) => {
                        emu.paused = paused;
                        if paused {
                            publish(&emu, &shared);
                            last_revision = Some(emu.bus.scanout_revision());
                        }
                        controls.fetch_sub(1, Ordering::Release);
                    }
                    Some(Command::PowerOff) => powered = false,
                    Some(Command::Reset { resume }) => {
                        match emu.reset() {
                            Ok(()) => {
                                if resume {
                                    emu.paused = false;
                                }
                                powered = true;
                                {
                                    let mut state = shared.lock().unwrap();
                                    state.error = None;
                                    #[cfg(test)]
                                    {
                                        state.steps = 0;
                                        state.ready = false;
                                    }
                                }
                                publish(&emu, &shared);
                                last_revision = Some(emu.bus.scanout_revision());
                            }
                            Err(error) => {
                                powered = false;
                                shared.lock().unwrap().error =
                                    Some(format!("Reset failed: {error}"));
                            }
                        }
                        controls.fetch_sub(1, Ordering::Release);
                    }
                    Some(Command::Frame) => {
                        let revision = emu.bus.scanout_revision();
                        if last_revision != Some(revision) {
                            publish(&emu, &shared);
                            last_revision = Some(revision);
                        }
                        pending.store(false, Ordering::Release);
                    }
                    Some(_) => {}
                    None => {
                        emu.step_frame(50_000);
                        #[cfg(test)]
                        {
                            let mut state = shared.lock().unwrap();
                            state.steps = emu.total_steps;
                            if !state.ready {
                                state.ready = emu
                                    .bus
                                    .console_output
                                    .windows(b"NIHOS_NATIVE_XY_READY".len())
                                    .any(|bytes| bytes == b"NIHOS_NATIVE_XY_READY");
                            }
                        }
                        let failure = emu
                            .fault()
                            .map(|fault| format!("Emulator stopped: {fault}"))
                            .or_else(|| {
                                String::from_utf8_lossy(&emu.bus.console_output)
                                    .lines()
                                    .find(|line| line.starts_with("NIHOS_NATIVE_FAIL "))
                                    .map(|line| format!("Guest stopped: {line}"))
                            });
                        if let Some(error) = failure {
                            powered = false;
                            publish(&emu, &shared);
                            shared.lock().unwrap().error = Some(error);
                        }
                    }
                }
            }
        });
        Self {
            tx,
            snapshot,
            frame_pending,
            pending_control,
            paused: false,
        }
    }
    pub fn send_arrow(&self, key: &str) {
        let _ = self.tx.send(Command::Arrow(key.to_owned()));
    }

    pub fn send_key(&self, key: u8) {
        let _ = self.tx.send(Command::Key(key));
    }
    pub fn paste(&self, bytes: Vec<u8>) {
        let _ = self.tx.send(Command::Paste(bytes));
    }
    pub fn touch(&self, point: Option<(u16, u16)>) {
        let _ = self.tx.send(Command::Touch(point));
    }
    pub fn set_paused(&mut self, paused: bool) {
        self.paused = paused;
        self.pending_control.fetch_add(1, Ordering::AcqRel);
        if self.tx.send(Command::Pause(paused)).is_err() {
            self.pending_control.fetch_sub(1, Ordering::Release);
        }
    }
    pub fn power_off(&self) {
        let _ = self.tx.send(Command::PowerOff);
    }
    pub fn reset(&mut self, resume: bool) {
        if resume {
            self.paused = false;
        }
        self.pending_control.fetch_add(1, Ordering::AcqRel);
        if self.tx.send(Command::Reset { resume }).is_err() {
            self.pending_control.fetch_sub(1, Ordering::Release);
        }
    }
    pub fn control_pending(&self) -> bool {
        self.pending_control.load(Ordering::Acquire) != 0
    }
    pub fn request_frame(&self) {
        if !self.frame_pending.swap(true, Ordering::AcqRel) && self.tx.send(Command::Frame).is_err()
        {
            self.frame_pending.store(false, Ordering::Release);
        }
    }
    pub fn snapshot(&self) -> (Option<Arc<Vec<u8>>>, u64, Option<String>) {
        let state = self.snapshot.lock().unwrap();
        (state.frame.clone(), state.revision, state.error.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn wait_for(mut condition: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !condition() {
            assert!(Instant::now() < deadline, "worker did not respond");
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    #[test]
    fn worker_pause_resume_reset_and_failure() {
        let mut image = vec![0u8; 88];
        image[..6].copy_from_slice(b"\x7fELF\x01\x01");
        image[16..18].copy_from_slice(&2u16.to_le_bytes());
        image[18..20].copy_from_slice(&243u16.to_le_bytes());
        image[24..28].copy_from_slice(&emu::bus::SRAM_BASE.to_le_bytes());
        image[28..32].copy_from_slice(&52u32.to_le_bytes());
        image[42..44].copy_from_slice(&32u16.to_le_bytes());
        image[44..46].copy_from_slice(&1u16.to_le_bytes());
        image[52..56].copy_from_slice(&1u32.to_le_bytes());
        image[56..60].copy_from_slice(&84u32.to_le_bytes());
        image[60..64].copy_from_slice(&emu::bus::SRAM_BASE.to_le_bytes());
        image[68..72].copy_from_slice(&4u32.to_le_bytes());
        image[72..76].copy_from_slice(&4u32.to_le_bytes());
        image[84..88].copy_from_slice(&0x0000006fu32.to_le_bytes()); // jal x0, 0
        let path = std::env::temp_dir().join(format!("nihos-worker-{}.elf", std::process::id()));
        std::fs::write(&path, image).unwrap();
        let mut worker = Worker::new(Emulator::new(&path, None::<&std::path::Path>).unwrap());
        wait_for(|| worker.snapshot.lock().unwrap().steps > 0);
        worker.set_paused(true);
        wait_for(|| !worker.control_pending());
        let paused_steps = worker.snapshot.lock().unwrap().steps;
        std::thread::sleep(Duration::from_millis(30));
        assert_eq!(worker.snapshot.lock().unwrap().steps, paused_steps);
        assert!(worker.snapshot().0.is_some());
        worker.reset(false);
        wait_for(|| !worker.control_pending());
        assert!(worker.paused);
        assert_eq!(worker.snapshot.lock().unwrap().steps, 0);
        worker.set_paused(false);
        wait_for(|| worker.snapshot.lock().unwrap().steps > 0);
        worker.power_off();
        worker.set_paused(true); // FIFO acknowledgement for power off
        wait_for(|| !worker.control_pending());
        let stopped_steps = worker.snapshot.lock().unwrap().steps;
        std::thread::sleep(Duration::from_millis(30));
        assert_eq!(worker.snapshot.lock().unwrap().steps, stopped_steps);
        std::fs::remove_file(&path).unwrap();
        worker.reset(true);
        wait_for(|| !worker.control_pending());
        assert!(worker.snapshot().2.unwrap().contains("Reset failed"));
    }
    #[test]
    #[ignore = "requires NIHOS_EMU_TEST_ELF"]
    fn worker_boots_guest_and_handles_pause() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").unwrap();
        let mut worker = Worker::new(Emulator::new(path, None::<&str>).unwrap());
        let deadline = Instant::now() + Duration::from_secs(60);
        while !worker.snapshot.lock().unwrap().ready {
            assert!(
                Instant::now() < deadline,
                "guest did not reach xy ready: {:?}",
                worker.snapshot().2
            );
            worker.request_frame();
            std::thread::sleep(Duration::from_millis(10));
        }
        let ready_steps = worker.snapshot.lock().unwrap().steps;
        wait_for(|| worker.snapshot.lock().unwrap().steps > ready_steps + 30_000_000);
        worker.set_paused(true);
        wait_for(|| !worker.control_pending());
        let (frame, _, error) = worker.snapshot();
        assert!(frame.is_some());
        assert!(error.is_none());
        let steps = worker.snapshot.lock().unwrap().steps;
        std::thread::sleep(Duration::from_millis(30));
        assert_eq!(worker.snapshot.lock().unwrap().steps, steps);
        worker.set_paused(false);
        worker.send_key(b'n');
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            worker.request_frame();
            if worker.snapshot().0.as_deref() != frame.as_deref() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "guest frame did not respond to input"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
