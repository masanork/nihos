#!/usr/bin/env python3
"""Validate a real native graphics image/log; ISA and physical evidence differ."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("native_base_log", Path(__file__).with_name("check-native-log.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
FIELDS = ("status", "owner", "runs", "library_pc", "heap_before", "heap_after", "raw_peak", "retained",
          "stack_low", "stack_high", "observed_used", "captures", "render_captures", "bootstrap_progress",
          "record_peak", "controller_bytes", "allocations", "releases", "foreign_rejected", "irq_rejected", "forged_rejected",
          "client_cycles", "idle_retained", "idle_captures", "idle_progress")

EXCHANGE_FIELDS = ("sent", "received", "replies", "waits", "blocked_ticks", "idle_runtime", "stop_ack", "terminal_gap", "copied_inputs", "text_success", "text_failed", "copied_outputs", "queue_bytes")
TEXT_FIELDS = ("id", "runs", "hash", "outcome", "glyph_count")
GLYPH_FIELDS = ("request", "index", "glyph_id", "cluster", "run", "pixels", "x_advance", "y_advance", "x_offset", "y_offset", "left", "top", "width", "height")
SIGNED_GLYPH_FIELDS = ("x_advance", "y_advance", "x_offset", "y_offset", "left", "top")


def validate(record, hashes, graphics, expected, exchange, texts, expected_texts):
    q = record
    entry = graphics["functions"]["graphics_font_link_probe"]
    if (q["status"] != 1 or q["runs"] != 16 or q["owner"] >> 24 != 0 or
            q["owner"] >> 16 & 255 != 1 or q["owner"] & 65535 < 3 or
            not int(entry["start"], 16) <= q["library_pc"] < int(entry["end"], 16) or
            not q["heap_before"] == q["heap_after"] > q["raw_peak"] >= 1310976 or q["retained"] != 65792 or
            q["stack_low"] != 0x4ff6e010 or q["stack_high"] != 0x4ff76000 or
            not 16384 <= q["observed_used"] < 32768 - 16 - 160 or
            not 0 < q["render_captures"] <= q["captures"] or q["bootstrap_progress"] < q["captures"] or
            not 512 < q["record_peak"] <= 1024 or q["controller_bytes"] != 17224 or
            q["allocations"] <= 1 or q["releases"] + 1 != q["allocations"] or
            not q["foreign_rejected"] or not q["irq_rejected"] or q["forged_rejected"] != 1 or
            q["client_cycles"] != 9 or q["idle_retained"] != q["retained"] or
            not 0 <= q["idle_captures"] <= q["captures"] - q["render_captures"] or
            not 10 <= q["idle_progress"] <= q["bootstrap_progress"]):
        raise ValueError("incomplete native font ownership/preemption/recovery evidence")
    if (any(exchange[n] != 10 for n in ("sent", "received", "replies", "waits")) or
            exchange["blocked_ticks"] < 20 or exchange["idle_runtime"] != 0 or exchange["stop_ack"] != 1 or exchange["terminal_gap"] != 1 or
            exchange["copied_inputs"] != 5 or exchange["copied_outputs"] != 5 or exchange["text_success"] != 3 or exchange["text_failed"] != 2 or
            not 512 <= exchange["queue_bytes"] <= 4096):
        raise ValueError("incomplete blocking font transport/shutdown evidence")
    if len(hashes) != 16 or hashes != expected:
        raise ValueError("native glyph/position/raster hashes differ from host reference")
    if any(t["glyph_count"] != len(t["glyphs"]) or t["glyph_count"] > 16 or
           (t["outcome"] == 0 and not t["glyph_count"]) or
           (t["outcome"] != 0 and (t["glyph_count"] or t["hash"] or t["runs"])) for t in texts):
        raise ValueError("invalid or partial native glyph output")
    if [r["id"] for r in texts] != [5, 6, 7, 8, 9] or texts != expected_texts:
        raise ValueError("native text results differ from independent host requests")
    return q


def check(log, image, manifest, reference, text_reference):
    if image["memory"]["profile"] != "emulator" or "graphics" not in image:
        raise ValueError("this smoke requires an audited emulator graphics image")
    log = log.replace("\\r", "").replace("\r", "")
    baseline = base.check(log, "integer", 32 << 20, image, evidence="emulator")
    q = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS", FIELDS[:-4])
    q.update(base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_CLIENTS", FIELDS[-4:]))
    exchange = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_EXCHANGE", EXCHANGE_FIELDS)
    texts = base.repeated_records(log, "NIHOS_NATIVE_GRAPHICS_TEXT", TEXT_FIELDS)
    for text in texts:
        text["glyphs"] = []
    for row in base.repeated_records(log, "NIHOS_NATIVE_GRAPHICS_GLYPH", GLYPH_FIELDS):
        target = next((t for t in texts if t["id"] == row["request"]), None)
        if target is None or row["index"] != len(target["glyphs"]) or row["index"] >= 16:
            raise ValueError("missing/reordered/overflowed glyph output")
        glyph = {name: row[name] for name in GLYPH_FIELDS[2:]}
        for name in SIGNED_GLYPH_FIELDS:
            if glyph[name] >= 1 << 31:
                glyph[name] -= 1 << 32
        target["glyphs"].append(glyph)
    if any(t["glyph_count"] != len(t["glyphs"]) for t in texts):
        raise ValueError("incomplete glyph output")
    rows = base.repeated_records(log, "NIHOS_NATIVE_GRAPHICS_HASH", ("index", "hash"))
    if [r["index"] for r in rows] != list(range(16)):
        raise ValueError("missing/reordered native font hash cases")
    if log.count("NIHOS_NATIVE_GRAPHICS_PASS\n") != 1 or not (
            log.index("NIHOS_NATIVE_FP_PASS ") < log.index("NIHOS_NATIVE_GRAPHICS ") <
            log.index("NIHOS_NATIVE_GRAPHICS_CLIENTS ") < log.index("NIHOS_NATIVE_GRAPHICS_EXCHANGE ") <
            log.index("NIHOS_NATIVE_GRAPHICS_TEXT ") <= log.rindex("NIHOS_NATIVE_GRAPHICS_TEXT ") <
            log.index("NIHOS_NATIVE_GRAPHICS_HASH ") <
            log.index("NIHOS_NATIVE_GRAPHICS_PASS\n")):
        raise ValueError("missing or out-of-order native graphics pass")
    profile = next(p for p in reference["profiles"] if p["render_pool_bytes"] == 2048 and p["allocation_records"] == 1024)
    expected = next(m["host"]["hashes"] for m in profile["modes"] if m["hinting"] == "auto")
    pins = {f["name"]: (f["bytes"], f["sha256"]) for f in reference["input_fonts"]}
    if {f["name"]: (f["bytes"], f["sha256"]) for f in manifest["fonts"]} != pins:
        raise ValueError("native font inputs differ from host reference")
    hashes = [r["hash"] for r in rows]
    if text_reference["cases_sha256"] != hashlib.sha256((ROOT / "probes/graphics/text_cases.json").read_bytes()).hexdigest():
        raise ValueError("text reference inputs differ from current canonical requests")
    validate(q, hashes, image["graphics"], expected, exchange, texts, text_reference["texts"])
    return {"status": "pass", "evidence": "esp32p4-emulator-native-image", "rtos_linked": False,
            "graphics": q, "exchange": exchange, "texts": texts, "hashes": hashes, "baseline": baseline,
            "limits": ["No physical Tab5 evidence", "Fonts are immutable Flash fixture inputs; no native SD/VFS font reads",
                       "Four matrix and five bounded text jobs share one live task; no service restart",
                       "Stack watermark and trap samples are observations, not arbitrary-font or IO call-chain upper bounds"]}


def main():
    directory = Path(sys.argv[1])
    output = directory / "graphics-smoke.json"
    output.unlink(missing_ok=True)
    image_path, manifest_path = directory / "image-audit.json", directory / "graphics-manifest.json"
    reference_path = ROOT / "docs/measurements/2026-10-28-graphics-hinting-stack.json"
    text_reference_path = ROOT / "docs/measurements/2026-10-28-font-glyph-host.json"
    image = json.loads(image_path.read_text())
    result = check((directory / "emulator.log").read_text(), image, json.loads(manifest_path.read_text()), json.loads(reference_path.read_text()), json.loads(text_reference_path.read_text()))
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    if sha(directory / "nihos-native.elf") != image["elf_sha256"] or sha(directory / "nihos-native.bin") != image["image_sha256"]:
        raise ValueError("captured native image identity differs from audit")
    result["artifacts_sha256"] = {p.name: sha(p) for p in [directory / n for n in ("nihos-native.elf", "nihos-native.bin", "nihos-native-flash.bin", "emulator.log", "image-audit.json", "graphics-manifest.json")]}
    result["text_reference_sha256"] = sha(text_reference_path)
    result["host_reference_sha256"] = sha(reference_path)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print("Native graphics: owned glyph metadata, atomic capacity failure, blocking waits, hashes and heap recovery passed")


if __name__ == "__main__":
    main()
