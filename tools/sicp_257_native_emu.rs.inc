    #[test]
    #[ignore = "requires traced native xy ELF"]
    fn sicp_257_eval_buffer_preview() {
        let path = std::env::var("NIHOS_EMU_TEST_ELF").unwrap();
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
        emu.step_frame(30_000_000); emu.send_key(b'n'); emu.step_frame(30_000_000);
        let source = include_str!("sicp_257_input.scm");
        let total = source.len();
        let mut entered = 0usize;
        for chunk in source.as_bytes().chunks(192) {
            let start = emu.bus.console_output.len();
            for byte in chunk { emu.send_key(*byte); }
            entered += chunk.len();
            wait(&mut emu, start, &format!("bytes={entered:08x}"));
            if entered < total {
                let start = emu.bus.console_output.len();
                emu.send_key(0x1b); wait(&mut emu,start,"mode=00000001");
                let start = emu.bus.console_output.len();
                for b in b"forget-undo\r" { emu.send_key(*b); }
                wait(&mut emu,start,"mode=00000000");
            }
        }
        let start=emu.bus.console_output.len(); emu.send_key(0x1b); wait(&mut emu,start,"mode=00000001");
        for b in b"eval-buffer\r" { emu.send_key(*b); }
        wait(&mut emu,start,"NIHOS_NATIVE_XY_REPLY data=");
        let start=emu.bus.console_output.len(); emu.send_key(0x1b); wait(&mut emu,start,"mode=00000001");
        for b in b"(deriv '(* x y (+ x 3)) 'x)\r" { emu.send_key(*b); }
        wait(&mut emu,start,"NIHOS_NATIVE_XY_REPLY data=282b20282a207820792920282a207920282b20782033292929");
        eprintln!("SICP_257_NATIVE original expression matched");
    }
