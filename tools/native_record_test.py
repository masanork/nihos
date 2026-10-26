"""Compile-time rejection is part of the type-erased record writer contract."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class NativeRecordSchemaTests(unittest.TestCase):
    def test_oversized_record_text_does_not_compile(self):
        root = Path(__file__).resolve().parent.parent
        zig = root / ".tools/zig-0.17.0/zig"
        if not zig.exists():
            subprocess.run(["sh", str(root / "tools/bootstrap-zig.sh")], check=True, capture_output=True)
        with tempfile.TemporaryDirectory(prefix="nihos-record-text-") as directory:
            source = Path(directory) / "invalid.zig"
            for length in (65532, 65536):
                source.write_text('const log = @import("record_log");\n'
                                  'const Sink = struct { pub fn write(_: @This(), _: []const u8) void {} };\n'
                                  'export fn check_schema() void {\n'
                                  '  const marker: [' + str(length) + ']u8 = @splat(109);\n'
                                  '  var value: extern struct { value: u32 } = undefined;\n'
                                  '  var writer = log.Writer(Sink){ .sink = .{} };\n'
                                  '  writer.record(&marker, null, .{"value"}, &value);\n}\n')
                result = subprocess.run([str(zig), "build-obj", "-fno-emit-bin", "--dep", "record_log",
                                         "-Mroot=" + str(source), "-Mrecord_log=" + str(root / "src/diagnostics/record.zig")],
                                        capture_output=True, text=True, timeout=30, cwd=root)
                with self.subTest(length=length):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("record text exceeds", result.stderr)

    def test_unsafe_schemas_do_not_compile(self):
        root = Path(__file__).resolve().parent.parent
        zig = root / ".tools/zig-0.17.0/zig"
        if not zig.exists():
            subprocess.run(["sh", str(root / "tools/bootstrap-zig.sh")], check=True, capture_output=True)
        cases = (
            ("struct { value: u64 }", "&value", "must be u32"),
            ("packed struct { value: u32 }", "&value", "unpacked struct"),
            ("struct { runtime: u32, comptime value: u32 = 1 }", "&value", "runtime storage"),
            ("struct { value: u32 }", "@as(*align(1) const Record, &value)", "pointer requires"),
            ("extern struct { padding: [65536]u8, value: u32 }", "&value", "descriptor format"),
        )
        with tempfile.TemporaryDirectory(prefix="nihos-record-schema-") as directory:
            source = Path(directory) / "invalid.zig"
            for declaration, pointer, expected in cases:
                source.write_text('const log = @import("record_log");\n'
                                  'const Sink = struct { pub fn write(_: @This(), _: []const u8) void {} };\n'
                                  'const Record = ' + declaration + ';\n'
                                  'export fn check_schema() void {\n'
                                  '  var value: Record = undefined;\n'
                                  '  var writer = log.Writer(Sink){ .sink = .{} };\n'
                                  '  writer.record("TEST", null, .{"value"}, ' + pointer + ');\n}\n')
                result = subprocess.run([str(zig), "build-obj", "-fno-emit-bin", "--dep", "record_log",
                                         "-Mroot=" + str(source), "-Mrecord_log=" + str(root / "src/diagnostics/record.zig")],
                                        capture_output=True, text=True, timeout=30, cwd=root)
                with self.subTest(declaration=declaration):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
