    #[test]
    #[ignore = "requires experimental continuation ELF"]
    fn continuation_native_poc_serial_resume_and_cancel() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        fn wait_for(emu: &mut Emulator, start: usize, marker: &str, quantum: usize, limit: usize) {
            for _ in 0..limit {
                emu.step_frame(quantum);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output.contains(marker) { eprintln!("POC observed {marker}"); return; }
                if marker.ends_with("state=00000003") && output.contains("NIHOS_NATIVE_XY_CONT_STATE state=00000002") {
                    panic!("evaluation completed before cancellation: {output}");
                }
            }
            panic!("missing {marker}: {}", String::from_utf8_lossy(&emu.bus.console_output[start..]));
        }
        fn command(emu: &mut Emulator, source: &str) -> usize {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            wait_for(emu, start, "mode=00000001", 1_000_000, 1000);
            for byte in source.bytes().chain(std::iter::once(b'\r')) { emu.send_key(byte); }
            start
        }
        wait_for(&mut emu, 0, "NIHOS_NATIVE_XY_READY", 1_000_000, 1000);
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        let setup = command(&mut emu, "(begin (define (count n) (if (= n 0) 0 (+ 1 (count (- n 1))))) 701)");
        wait_for(&mut emu, setup, "NIHOS_NATIVE_XY_REPLY data=373031", 1_000_000, 1000);
        let first = command(&mut emu, "(count 60)");
        wait_for(&mut emu, first, "NIHOS_NATIVE_XY_CONT_STATE state=00000001", 100_000, 10000);
        wait_for(&mut emu, first, "NIHOS_NATIVE_XY_REPLY data=3630", 1_000_000, 2000);
        wait_for(&mut emu, first, "NIHOS_NATIVE_XY_CONT_STATE state=00000002", 1_000_000, 1000);
        let second = command(&mut emu, "(count 80)");
        wait_for(&mut emu, second, "NIHOS_NATIVE_XY_CONT_STATE state=00000001", 100_000, 10000);
        emu.send_key(b'x'); // deferred before the prioritized cancellation
        emu.send_key(3);
        wait_for(&mut emu, second, "NIHOS_NATIVE_XY_CONT_STATE state=00000003", 100_000, 10000);
        wait_for(&mut emu, second, " bytes=00000001 cursor=00000001 ", 1_000_000, 1000);
        let output = String::from_utf8_lossy(&emu.bus.console_output[second..]);
        assert!(!output.contains("NIHOS_NATIVE_XY_REPLY data=3830"), "cancelled evaluation completed: {output}");
        let recovery = command(&mut emu, "(+ 20 22)");
        wait_for(&mut emu, recovery, "NIHOS_NATIVE_XY_REPLY data=3432", 1_000_000, 1000);
        eprintln!("POC resumed=count60 cancelled=count80 replay=x recovery=42");
    }
    #[test]
    #[ignore = "requires experimental continuation ELF"]
    fn continuation_native_poc_sicp_127() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        fn wait(emu: &mut Emulator, start: usize, expected: &str) {
            for _ in 0..1000 {
                emu.step_frame(1_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output.contains(expected) { eprintln!("POC sicp observed {expected}"); return; }
            }
            panic!("missing {expected}: {}", String::from_utf8_lossy(&emu.bus.console_output[start..]));
        }
        fn command(emu: &mut Emulator, source: &str) -> usize {
            let start = emu.bus.console_output.len(); emu.send_key(0x1b); wait(emu, start, "mode=00000001");
            for byte in source.bytes().chain(std::iter::once(b'\r')) { emu.send_key(byte); }
            start
        }
        wait(&mut emu, 0, "NIHOS_NATIVE_XY_READY"); emu.step_frame(30_000_000); emu.send_key(b'n'); emu.step_frame(30_000_000);
        let setup = command(&mut emu, "(begin (define (expmod base exp m) (cond ((= exp 0) 1) ((even? exp) (let ((x (expmod base (quotient exp 2) m))) (remainder (* x x) m))) (else (remainder (* base (expmod base (- exp 1) m)) m)))) 703)");
        wait(&mut emu, setup, "NIHOS_NATIVE_XY_REPLY data=373033");
        let setup2 = command(&mut emu, "(begin (define (fermat? a n) (= (expmod a n n) a)) 704)");
        wait(&mut emu, setup2, "NIHOS_NATIVE_XY_REPLY data=373034");
        for n in [2465, 2821, 6601] {
            for a in [2, 3, 10] {
                let expression = format!("(fermat? {a} {n})");
                let exercise = command(&mut emu, &expression);
                wait(&mut emu, exercise, "NIHOS_NATIVE_XY_CONT_STATE state=00000001");
                wait(&mut emu, exercise, "NIHOS_NATIVE_XY_REPLY data=2374");
                eprintln!("POC sicp 1.27 {expression} => #t");
            }
        }
    }
    #[test]
    #[ignore = "requires experimental continuation ELF"]
    fn continuation_native_poc_scratch_placement() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        for _ in 0..1000 {
            emu.step_frame(1_000_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output);
            assert!(!emu.paused && !output.contains("NIHOS_NATIVE_FAIL"), "{output}");
            if let Some(line) = output.lines().find(|s| s.contains("NIHOS_NATIVE_XY_PSRAM ")) {
                let field = |name: &str| -> u32 { u32::from_str_radix(line.split_whitespace().find_map(|p| p.strip_prefix(name)).unwrap(), 16).unwrap() };
                let address = field("address="); let bytes = field("bytes="); let reserved = field("reserved=");
                assert!(address >= 0x4820_0000 && address.checked_add(bytes).is_some_and(|end| end <= 0x4a00_0000), "{line}");
                assert!(reserved >= bytes, "{line}");
                eprintln!("POC placement {line}"); return;
            }
        }
        panic!("missing scratch placement");
    }
    #[test]
    #[ignore = "requires experimental continuation ELF; set NIHOS_YIELD_GC_EXPECT"]
    fn continuation_native_poc_yield_gc_retained_graph() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let expected = std::env::var("NIHOS_YIELD_GC_EXPECT").expect("set NIHOS_YIELD_GC_EXPECT");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        fn wait(emu: &mut Emulator, start: usize, marker: &str, limit: usize) {
            for _ in 0..limit {
                emu.step_frame(1_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output.contains(marker) { eprintln!("YIELD POC observed {marker}"); return; }
            }
            panic!("missing {marker}: {}", String::from_utf8_lossy(&emu.bus.console_output[start..]));
        }
        fn command(emu: &mut Emulator, source: &str, reply: &str) -> usize {
            assert!(source.len() < 256);
            let mode_start = emu.bus.console_output.len();
            emu.send_key(0x1b); wait(emu, mode_start, "mode=00000001", 1000);
            let start = emu.bus.console_output.len();
            for byte in source.bytes().chain(std::iter::once(b'\r')) { emu.send_key(byte); }
            wait(emu, start, reply, 4000); start
        }
        wait(&mut emu, 0, "NIHOS_NATIVE_XY_READY", 1000); emu.step_frame(30_000_000); emu.send_key(b'n'); emu.step_frame(30_000_000);
        let seed = format!("(begin (define retained '( {})) 701)", "0 ".repeat(100));
        command(&mut emu, &seed, "NIHOS_NATIVE_XY_REPLY data=373031");
        for _ in 0..2 { command(&mut emu, "(begin (set! retained (append retained retained)) (set! retained (append retained retained)) 702)", "NIHOS_NATIVE_XY_REPLY data=373032"); }
        command(&mut emu, "(begin (set! retained (append retained retained)) 702)", "NIHOS_NATIVE_XY_REPLY data=373032");
        command(&mut emu, "(length retained)", "NIHOS_NATIVE_XY_REPLY data=33323030");
        let defs = "(begin (define (churn n acc) (if (= n 0) acc (churn (- n 1) (cons n acc)))) (define (nth xs n) (if (= n 0) (car xs) (nth (cdr xs) (- n 1)))) 703)";
        command(&mut emu, defs, "NIHOS_NATIVE_XY_REPLY data=373033");
        if let Ok(entry) = std::env::var("NIHOS_YIELD_GC_ENTRY") {
            emu.gc_probe = Some(GcInstructionProbe { entry: u32::from_str_radix(entry.trim_start_matches("0x"), 16).unwrap(), active: None, samples: Vec::new() });
        }
        let target = if expected == "done" { "NIHOS_NATIVE_XY_REPLY data=3231" } else { "NIHOS_NATIVE_XY_REPLY data=536368656d6520686561702066756c6c" };
        let start = command(&mut emu, "(nth (churn 180 '()) 20)", target);
        let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
        assert!(output.contains("NIHOS_NATIVE_XY_CONT_STATE state=00000001"), "continuation not selected: {output}");
        if expected == "done" {
            let event_marker = if std::env::var_os("NIHOS_SLICED_GC").is_some() { "NIHOS_NATIVE_XY_GC_DONE count=" } else { "NIHOS_NATIVE_XY_GC_YIELD_POC collections=" };
            let events: Vec<_> = output.lines().filter(|line| line.contains(event_marker)).collect();
            assert!(!events.is_empty(), "yield GC not observed: {output}");
            for event in events { eprintln!("YIELD POC gc {event}"); }
            if let Some(probe) = emu.gc_probe.take() {
                assert!(!probe.samples.is_empty(), "collector entry not observed");
                eprintln!("YIELD POC collector_instructions count={} min={} max={} samples={:?}", probe.samples.len(), probe.samples.iter().min().unwrap(), probe.samples.iter().max().unwrap(), probe.samples);
            }
        }
        command(&mut emu, "(car retained)", "NIHOS_NATIVE_XY_REPLY data=30");
        command(&mut emu, "(+ 20 22)", "NIHOS_NATIVE_XY_REPLY data=3432");
        eprintln!("YIELD POC expectation={expected} retained=0 recovery=42");
    }
    #[test]
    #[ignore = "requires experimental sliced continuation ELF"]
    fn continuation_native_poc_sliced_gc_cancel() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        fn wait(emu: &mut Emulator, start: usize, marker: &str, step: usize, limit: usize) {
            for _ in 0..limit {
                emu.step_frame(step);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output.contains(marker) { eprintln!("SLICED POC observed {marker}"); return; }
            }
            panic!("missing {marker}: {}", String::from_utf8_lossy(&emu.bus.console_output[start..]));
        }
        fn command(emu: &mut Emulator, source: &str, reply: &str) {
            assert!(source.len() < 256);
            let mode = emu.bus.console_output.len(); emu.send_key(0x1b);
            wait(emu, mode, "mode=00000001", 1_000_000, 1000);
            let start = emu.bus.console_output.len();
            for byte in source.bytes().chain(std::iter::once(b'\r')) { emu.send_key(byte); }
            wait(emu, start, reply, 1_000_000, 4000);
        }
        wait(&mut emu, 0, "NIHOS_NATIVE_XY_READY", 1_000_000, 1000);
        emu.step_frame(30_000_000); emu.send_key(b'n'); emu.step_frame(30_000_000);
        let seed = format!("(begin (define retained '( {})) 701)", "0 ".repeat(100));
        command(&mut emu, &seed, "NIHOS_NATIVE_XY_REPLY data=373031");
        for _ in 0..2 { command(&mut emu, "(begin (set! retained (append retained retained)) (set! retained (append retained retained)) 702)", "NIHOS_NATIVE_XY_REPLY data=373032"); }
        command(&mut emu, "(begin (set! retained (append retained retained)) 702)", "NIHOS_NATIVE_XY_REPLY data=373032");
        command(&mut emu, "(length retained)", "NIHOS_NATIVE_XY_REPLY data=33323030");
        command(&mut emu, "(begin (define (churn n acc) (if (= n 0) acc (churn (- n 1) (cons n acc)))) (define (nth xs n) (if (= n 0) (car xs) (nth (cdr xs) (- n 1)))) 703)", "NIHOS_NATIVE_XY_REPLY data=373033");
        let mode = emu.bus.console_output.len(); emu.send_key(0x1b);
        wait(&mut emu, mode, "mode=00000001", 1_000_000, 1000);
        let start = emu.bus.console_output.len();
        for byte in "(nth (churn 180 '()) 20)".bytes().chain(std::iter::once(b'\r')) { emu.send_key(byte); }
        wait(&mut emu, start, "NIHOS_NATIVE_XY_GC_STATE state=00000001", 1000, 1_000_000);
        emu.send_key(b'x'); emu.send_key(3);
        wait(&mut emu, start, "NIHOS_NATIVE_XY_GC_STATE state=00000002", 1000, 1_000_000);
        wait(&mut emu, start, "NIHOS_NATIVE_XY_GC_DONE count=00000001", 100_000, 10000);
        wait(&mut emu, start, "NIHOS_NATIVE_XY_CONT_STATE state=00000002", 100_000, 10000);
        wait(&mut emu, start, " bytes=00000001 cursor=00000001 ", 1_000_000, 1000);
        let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
        assert!(!output.contains("NIHOS_NATIVE_XY_REPLY data=3231"), "cancelled evaluation completed: {output}");
        command(&mut emu, "(length retained)", "NIHOS_NATIVE_XY_REPLY data=33323030");
        command(&mut emu, "(+ 20 22)", "NIHOS_NATIVE_XY_REPLY data=3432");
        eprintln!("SLICED POC cancel drained replay=x retained=3200 recovery=42");
    }
    #[test]
    #[ignore = "requires candidate ELF and foreground entry addresses"]
    fn continuation_native_foreground_rejects_other_hart() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        for key in ["NIHOS_XY_EVALUATE_ENTRY", "NIHOS_XY_RESUME_ENTRY", "NIHOS_XY_ON_STACK_ENTRY"] {
            let entry = u32::from_str_radix(std::env::var(key).expect(key).trim_start_matches("0x"), 16).unwrap();
            let mut emu = Emulator::new(&path, None::<&str>).unwrap();
            emu.cpu = Cpu::new(entry);
            emu.cpu.mhartid = 1;
            let sentinel = 0x4000_0200;
            emu.cpu.x[1] = sentinel;
            emu.cpu.x[10] = 0; // Must return before dereferencing the model.
            for _ in 0..128 {
                if emu.cpu.pc == sentinel { break; }
                assert!(emu.cpu.step(&mut emu.bus), "{key}: {:?}", emu.cpu.fault);
            }
            assert_eq!(emu.cpu.pc, sentinel, "{key} did not reject hart 1");
            eprintln!("HART_GUARD {key} returned on hart 1");
        }
    }
    #[test]
    #[ignore = "requires no-sqld candidate ELF with XY trace"]
    fn continuation_native_resume_rejects_corrupt_stack_guard() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        fn wait(emu: &mut Emulator, start: usize, marker: &str, step: usize, limit: usize) {
            for _ in 0..limit {
                emu.step_frame(step);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                if output.contains(marker) { eprintln!("STACK_GUARD observed {marker}"); return; }
            }
            panic!("missing {marker}: {}", String::from_utf8_lossy(&emu.bus.console_output[start..]));
        }
        wait(&mut emu, 0, "NIHOS_NATIVE_XY_READY", 1_000_000, 1000);
        let allocation = String::from_utf8_lossy(&emu.bus.console_output).lines().find(|s| s.contains("NIHOS_NATIVE_XY_PSRAM ")).unwrap().to_owned();
        let field = |name: &str| -> u32 { u32::from_str_radix(allocation.split_whitespace().find_map(|p| p.strip_prefix(name)).unwrap(), 16).unwrap() };
        let address = field("address="); let bytes = field("bytes="); let stack_bytes = field("stack_bytes=");
        assert_eq!(stack_bytes, 65536);
        let stack = address + bytes - stack_bytes;
        emu.step_frame(30_000_000); emu.send_key(b'n'); emu.step_frame(30_000_000);
        let mode = emu.bus.console_output.len(); emu.send_key(0x1b);
        wait(&mut emu, mode, "mode=00000001", 1_000_000, 1000);
        let setup = emu.bus.console_output.len();
        for b in "(begin (define (count n) (if (= n 0) 0 (+ 1 (count (- n 1))))) 701)".bytes().chain(std::iter::once(b'\r')) { emu.send_key(b); }
        wait(&mut emu, setup, "NIHOS_NATIVE_XY_REPLY data=373031", 1_000_000, 1000);
        let mode = emu.bus.console_output.len(); emu.send_key(0x1b);
        wait(&mut emu, mode, "mode=00000001", 1_000_000, 1000);
        let start = emu.bus.console_output.len();
        for b in "(count 60)".bytes().chain(std::iter::once(b'\r')) { emu.send_key(b); }
        wait(&mut emu, start, "NIHOS_NATIVE_XY_CONT_STATE state=00000001", 1000, 1_000_000);
        // Stop only after one resume has returned. Corruption injected during
        // a resume is also caught by the old post-call guard check and would
        // not distinguish it from checking the guard before the next resume.
        let resume = u32::from_str_radix(std::env::var("NIHOS_XY_RESUME_ENTRY").expect("set NIHOS_XY_RESUME_ENTRY").trim_start_matches("0x"), 16).unwrap();
        let mut return_pc = None;
        for _ in 0..2_000_000 {
            if return_pc.is_none() && emu.cpu.pc == resume { return_pc = Some(emu.cpu.x[1]); }
            if return_pc.is_some_and(|pc| emu.cpu.pc == pc) { break; }
            assert!(emu.cpu.step(&mut emu.bus), "guest fault while finding resume: {:?}", emu.cpu.fault);
        }
        assert!(return_pc.is_some_and(|pc| emu.cpu.pc == pc), "resume did not return");
        emu.bus.write_u32(stack, 0);
        for _ in 0..2000 {
            emu.step_frame(100_000);
            let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
            if output.contains("NIHOS_NATIVE_TASK_FAIL") { eprintln!("STACK_GUARD corruption detected before resume"); return; }
            assert!(!output.contains("NIHOS_NATIVE_XY_REPLY data=3630"), "corrupt guard was overwritten and evaluation completed");
            assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
        }
        panic!("corrupt guard was not detected");
    }
    #[test]
    #[ignore = "requires candidate ELF and foreground service address"]
    fn continuation_native_service_rejects_other_hart() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let entry = u32::from_str_radix(std::env::var("NIHOS_XY_SERVICE_ENTRY").expect("set NIHOS_XY_SERVICE_ENTRY").trim_start_matches("0x"), 16).unwrap();
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        emu.cpu = Cpu::new(entry);
        emu.cpu.mhartid = 1;
        let sentinel = 0x4000_0200;
        emu.cpu.x[1] = sentinel;
        emu.cpu.x[10] = 0;
        for _ in 0..256 {
            if emu.cpu.pc == sentinel { break; }
            assert!(emu.cpu.step(&mut emu.bus), "service: {:?}", emu.cpu.fault);
        }
        assert_eq!(emu.cpu.pc, sentinel, "service did not return on hart 1");
        assert_eq!(emu.cpu.x[10], 0, "service did not reject hart 1");
        eprintln!("HART_GUARD UI service rejected hart 1");
    }

    #[test]
    #[ignore = "requires traced native xy ELF with recursive bindings"]
    fn recursive_bindings_native_smoke() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        fn wait(emu: &mut Emulator, start: usize, marker: &str) {
            for _ in 0..1500 {
                emu.step_frame(1_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output.contains(marker) { return; }
            }
            panic!("missing {marker}: {}", String::from_utf8_lossy(&emu.bus.console_output[start..]));
        }
        wait(&mut emu, 0, "NIHOS_NATIVE_XY_READY");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, answer) in [
            ("(let loop ((n 50) (a 0)) (if (= n 0) a (loop (- n 1) (+ a 1))))", "3530"),
            ("(letrec ((f (lambda (n) (if (= n 0) 0 (f (- n 1)))))) (f 50))", "30"),
            ("(letrec* ((x 7) (y (+ x 2))) y)", "39"),
            ("(letrec ((fact (lambda (n) (if (= n 1) 1 (* n (fact (- n 1))))))) (fact 10))", "33363238383030"),
            ("(+ 20 22)", "3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            wait(&mut emu, start, "mode=00000001");
            for byte in source.bytes().chain(std::iter::once(b'\r')) { emu.send_key(byte); }
            wait(&mut emu, start, &format!("NIHOS_NATIVE_XY_REPLY data={answer}"));
            eprintln!("RECURSIVE_NATIVE {source} => {answer}");
        }
    }

    #[test]
    #[ignore = "requires traced native xy ELF with list quasiquote"]
    fn quasiquote_native_smoke() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").expect("set NIHOS_EMU_TEST_ELF");
        let mut emu = Emulator::new(path, None::<&str>).unwrap();
        fn wait(emu: &mut Emulator, start: usize, marker: &str) {
            for _ in 0..1500 {
                emu.step_frame(1_000_000);
                assert!(!emu.paused, "guest fault: {:?}", emu.cpu.fault);
                let output = String::from_utf8_lossy(&emu.bus.console_output[start..]);
                assert!(!output.contains("NIHOS_NATIVE_FAIL"), "{output}");
                if output.contains(marker) { return; }
            }
            panic!("missing {marker}: {}", String::from_utf8_lossy(&emu.bus.console_output[start..]));
        }
        wait(&mut emu, 0, "NIHOS_NATIVE_XY_READY");
        emu.step_frame(30_000_000);
        emu.send_key(b'n');
        emu.step_frame(30_000_000);
        for (source, answer) in [
            ("(let ((x 2)) `(1 ,x 3))", "28312032203329"),
            ("`(a ,(+ 1 2) ,@(list 4 5) . ,(+ 2 5))", "2861203320342035202e203729"),
            ("(let ((x 2)) `(a `(b ,x ,,x) ,x))", "28612028717561736971756f74652028622028756e71756f74652078292028756e71756f74652032292929203229"),
            ("(+ 20 22)", "3432"),
        ] {
            let start = emu.bus.console_output.len();
            emu.send_key(0x1b);
            wait(&mut emu, start, "mode=00000001");
            for byte in source.bytes().chain(std::iter::once(b'\r')) { emu.send_key(byte); }
            wait(&mut emu, start, &format!("NIHOS_NATIVE_XY_REPLY data={answer}"));
            eprintln!("QUASIQUOTE_NATIVE {source} => {answer}");
        }
    }
