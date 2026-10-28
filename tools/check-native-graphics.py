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
TEXT_FIELDS = ("id", "runs", "hash", "outcome", "glyph_count", "pixel_bytes", "pixel_hash", "source_hash", "surface_hash", "wrap_hash", "policy_hash", "ruby_hash")
GLYPH_FIELDS = ("request", "index", "glyph_id", "cluster", "run", "pixels", "x_advance", "y_advance", "x_offset", "y_offset", "left", "top", "width", "height", "pixel_offset")
SIGNED_GLYPH_FIELDS = ("x_advance", "y_advance", "x_offset", "y_offset", "left", "top")

RASTER_FIELDS = ("created", "discarded", "published", "reclaimed", "live_charge", "peak_charge", "held_ticks", "stale_rejected", "foreign_rejected")

SURFACE_FIELDS = ("frames", "blits", "clipped", "guards", "rejected", "peak_charge", "live_charge")


PLACEMENT_FIELDS = ("paint_pc", "draw_pc", "frames", "draws", "context_checks", "irq_rejected", "active_ticks", "flash_ticks", "trap_pc")


def validate_placement(record, graphics):
    render = graphics["render"]
    for field, name in (("paint_pc", "native_surface.paint"), ("draw_pc", "native_surface.draw")):
        bounds = render["functions"][name]
        if not int(bounds["start"], 16) <= record[field] < int(bounds["end"], 16):
            raise ValueError("renderer execution PC differs from audited Flash function")
    if (record["frames"] != 3 or record["draws"] != 124 or record["context_checks"] != 6 or
            record["irq_rejected"] < 6 or not 0 < record["flash_ticks"] <= record["active_ticks"] <= record["irq_rejected"] or
            not int(render["start"], 16) <= record["trap_pc"] < int(render["end"], 16)):
        raise ValueError("incomplete task-only Flash rendering/preemption evidence")


SOURCE_FIELDS = ("input_pc", "prepare_pc", "verify_pc", "staged", "maps", "rejected", "edited", "poisoned", "echoed", "stale", "content", "annotations", "map_mutations", "wrong_reply")


def validate_source(record, graphics):
    for field, name in (("input_pc", "native_font_exchange.stageText"), ("prepare_pc", "native_surface.prepare"), ("verify_pc", "native_surface.verify")):
        bounds = graphics["render"]["functions"][name]
        if not int(bounds["start"], 16) <= record[field] < int(bounds["end"], 16):
            raise ValueError("runtime source execution outside audited Flash function")
    if tuple(record[k] for k in SOURCE_FIELDS[3:]) != (5, 10, 5, 1, 5, 5, 3, 3, 3, 3, 3):
        raise ValueError("incomplete runtime source ownership and rejection evidence")


RUBY_FIELDS = ("frames", "groups", "moved", "wide", "units", "joins", "lines", "clipped", "plan_bytes", "scratch_bytes")


def validate_ruby(record, texts, reference):
    if tuple(record[k] for k in RUBY_FIELDS) != (3, 2, 2, 1, 19, 2, 8, 0, 172, 320):
        raise ValueError("incomplete anchored group-ruby evidence")
    expected = {f["id"]: f["ruby_hash"] for f in reference["frames"]}
    if any(t["ruby_hash"] != expected.get(t["id"], 0) for t in texts):
        raise ValueError("native ruby composition differs from independent reference")
    if (sum(f["moved"] for f in reference["frames"]) != 2 or
            any(f["groups"] and f["ruby_hash"] == f["control_hash"] for f in reference["frames"])):
        raise ValueError("missing fixed-origin ruby negative control")


POLICY_FIELDS = ("frames", "spans", "joined", "lines", "transitions", "clipped")
WRAP_FIELDS = ("frames", "clusters", "lines", "wrapped_runs", "transitions", "clipped")
ARCHIVE_FIELDS = ("logical_bytes", "charge", "live_charge", "before", "after")


def validate_policy(record, texts, reference):
    if tuple(record[k] for k in POLICY_FIELDS) != (3, 28, 3, 9, 4, 0):
        raise ValueError("incomplete basic Japanese prohibition evidence")
    expected = {f["id"]: f["policy_hash"] for f in reference["frames"]}
    if any(t["policy_hash"] != expected.get(t["id"], 0) for t in texts):
        raise ValueError("native kinsoku composition differs from independent reference")
    if (sum(f["naive_forbidden_starts"] for f in reference["frames"]) != 2 or
            any(f["forbidden_starts"] or f["forbidden_ends"] for f in reference["frames"])):
        raise ValueError("missing Japanese prohibition negative control")


def validate_wrap(record, texts, reference):
    if tuple(record[k] for k in WRAP_FIELDS) != (3, 31, 8, 2, 3, 0):
        raise ValueError("incomplete bounded cluster wrapping evidence")
    expected = {f["id"]: f["wrap_hash"] for f in reference["frames"]}
    if any(t["wrap_hash"] != expected.get(t["id"], 0) for t in texts):
        raise ValueError("native wrapped composition differs from independent reference")


def validate_archive(record, graphics):
    if (record["logical_bytes"] != 3336 or record["charge"] != 4096 or record["live_charge"] != 0 or
            record["before"] != record["after"] or record["after"] != graphics["heap_before"] + record["charge"]):
        raise ValueError("incomplete diagnostic archive heap recovery")


def validate_surface(record, texts, reference):
    if (record["frames"] != 3 or record["blits"] != 31 or record["clipped"] != 5 or
            record["guards"] != 3 or record["rejected"] != 6 or record["peak_charge"] != 65536 or record["live_charge"] != 0):
        raise ValueError("incomplete surface composition/guard evidence")
    expected = {f["id"]: f["surface_hash"] for f in reference["frames"]}
    if any(t["surface_hash"] != expected.get(t["id"], 0) for t in texts):
        raise ValueError("native RGB565 composition differs from independent reference")


def validate_raster(record):
    if (record["created"] != 5 or record["discarded"] != 2 or record["published"] != 3 or record["reclaimed"] != 3 or
            record["live_charge"] != 0 or record["peak_charge"] != 32768 or record["held_ticks"] < 6 or
            record["stale_rejected"] < 8 or record["foreign_rejected"] != 3):
        raise ValueError("incomplete raster lease/release evidence")


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
           (t["outcome"] != 0 and (t["glyph_count"] or t["hash"] or t["runs"] or t["pixel_bytes"] or t["pixel_hash"])) for t in texts):
        raise ValueError("invalid or partial native glyph output")
    for text in texts:
        used = 0
        for glyph in text["glyphs"]:
            if glyph["pixel_offset"] != used or glyph["width"] > 256 or glyph["height"] > 256:
                raise ValueError("invalid raster glyph range")
            used += glyph["width"] * glyph["height"]
        if used != text["pixel_bytes"] or used > 16384:
            raise ValueError("invalid raster byte count")
    if [r["id"] for r in texts] != [5, 6, 7, 8, 9] or [{k: v for k, v in t.items() if k not in ("surface_hash", "wrap_hash", "policy_hash", "ruby_hash")} for t in texts] != expected_texts:
        raise ValueError("native text results differ from independent host requests")
    return q


def check(log, image, manifest, reference, text_reference, surface_reference, wrap_reference, policy_reference, ruby_reference):
    if image["memory"]["profile"] != "emulator" or "graphics" not in image:
        raise ValueError("this smoke requires an audited emulator graphics image")
    log = log.replace("\\r", "").replace("\r", "")
    baseline = base.check(log, "integer", 32 << 20, image, evidence="emulator")
    q = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS", FIELDS[:-4])
    q.update(base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_CLIENTS", FIELDS[-4:]))
    exchange = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_EXCHANGE", EXCHANGE_FIELDS)
    raster = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_RASTER", RASTER_FIELDS)
    validate_raster(raster)
    placement = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_PLACEMENT", PLACEMENT_FIELDS)
    surface = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_SURFACE", SURFACE_FIELDS)
    wrap = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_WRAP", WRAP_FIELDS)
    policy = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_KINSOKU", POLICY_FIELDS)
    source = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_SOURCE", SOURCE_FIELDS)
    ruby = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_RUBY", RUBY_FIELDS)
    archive = base.fixed_record(log, "NIHOS_NATIVE_GRAPHICS_ARCHIVE", ARCHIVE_FIELDS)
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
            log.index("NIHOS_NATIVE_GRAPHICS_CLIENTS ") < log.index("NIHOS_NATIVE_GRAPHICS_EXCHANGE ") < log.index("NIHOS_NATIVE_GRAPHICS_RASTER ") < log.index("NIHOS_NATIVE_GRAPHICS_PLACEMENT ") < log.index("NIHOS_NATIVE_GRAPHICS_SURFACE ") <
            log.index("NIHOS_NATIVE_GRAPHICS_WRAP ") < log.index("NIHOS_NATIVE_GRAPHICS_KINSOKU ") < log.index("NIHOS_NATIVE_GRAPHICS_SOURCE ") < log.index("NIHOS_NATIVE_GRAPHICS_RUBY ") < log.index("NIHOS_NATIVE_GRAPHICS_TEXT ") <= log.rindex("NIHOS_NATIVE_GRAPHICS_TEXT ") <
            log.index("NIHOS_NATIVE_GRAPHICS_HASH ") <
            log.index("NIHOS_NATIVE_GRAPHICS_ARCHIVE ") < log.index("NIHOS_NATIVE_GRAPHICS_PASS\n")):
        raise ValueError("missing or out-of-order native graphics pass")
    profile = next(p for p in reference["profiles"] if p["render_pool_bytes"] == 2048 and p["allocation_records"] == 1024)
    expected = next(m["host"]["hashes"] for m in profile["modes"] if m["hinting"] == "auto")
    pins = {f["name"]: (f["bytes"], f["sha256"]) for f in reference["input_fonts"]}
    if {f["name"]: (f["bytes"], f["sha256"]) for f in manifest["fonts"]} != pins:
        raise ValueError("native font inputs differ from host reference")
    hashes = [r["hash"] for r in rows]
    for key, path in (("cases_sha256", "runtime_text_cases.json"), ("annotations_sha256", "runtime_ruby_cases.json"), ("input_cases_sha256", "text_cases.json"), ("input_annotations_sha256", "ruby_cases.json")):
        if text_reference[key] != hashlib.sha256((ROOT / "probes/graphics" / path).read_bytes()).hexdigest():
            raise ValueError("runtime text reference differs from canonical input/edit")
    for path, digest in text_reference["sources_sha256"].items():
        if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != digest:
            raise ValueError("runtime reference differs from composition source")
    validate(q, hashes, image["graphics"], expected, exchange, texts, text_reference["texts"])
    validate_placement(placement, image["graphics"])
    validate_surface(surface, texts, surface_reference)
    validate_wrap(wrap, texts, wrap_reference)
    validate_policy(policy, texts, policy_reference)
    validate_source(source, image["graphics"])
    validate_ruby(ruby, texts, ruby_reference)
    validate_archive(archive, q)
    if archive["after"] != baseline["heaps"][0]["free"]:
        raise ValueError("archive retirement differs from original CPU0 heap")
    return {"status": "pass", "evidence": "esp32p4-emulator-native-image", "rtos_linked": False,
            "graphics": q, "exchange": exchange, "raster": raster, "placement": placement, "surface": surface, "wrap": wrap, "policy": policy, "ruby": ruby, "source": source, "archive": archive, "texts": texts, "hashes": hashes, "baseline": baseline,
            "limits": ["No physical Tab5 evidence", "Fonts are immutable Flash fixture inputs; no native SD/VFS font reads",
                       "Four matrix and five bounded text jobs share one live task; no service restart",
                       "Stack watermark and trap samples are observations, not arbitrary-font or IO call-chain upper bounds"]}


def main():
    directory = Path(sys.argv[1])
    output = directory / "graphics-smoke.json"
    output.unlink(missing_ok=True)
    image_path, manifest_path = directory / "image-audit.json", directory / "graphics-manifest.json"
    reference_path = ROOT / "docs/measurements/2026-10-28-graphics-hinting-stack.json"
    text_reference_path = ROOT / "docs/measurements/2026-10-28-runtime-text-reference.json"
    surface_reference_path = ROOT / "docs/measurements/2026-10-28-runtime-text-reference.json"
    wrap_reference_path = ROOT / "docs/measurements/2026-10-28-runtime-text-reference.json"
    policy_reference_path = ROOT / "docs/measurements/2026-10-28-runtime-text-reference.json"
    ruby_reference_path = ROOT / "docs/measurements/2026-10-28-runtime-text-reference.json"
    image = json.loads(image_path.read_text())
    result = check((directory / "emulator.log").read_text(), image, json.loads(manifest_path.read_text()), json.loads(reference_path.read_text()), json.loads(text_reference_path.read_text()), json.loads(surface_reference_path.read_text()), json.loads(wrap_reference_path.read_text()), json.loads(policy_reference_path.read_text()), json.loads(ruby_reference_path.read_text()))
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    if sha(directory / "nihos-native.elf") != image["elf_sha256"] or sha(directory / "nihos-native.bin") != image["image_sha256"]:
        raise ValueError("captured native image identity differs from audit")
    result["artifacts_sha256"] = {p.name: sha(p) for p in [directory / n for n in ("nihos-native.elf", "nihos-native.bin", "nihos-native-flash.bin", "emulator.log", "emulator-stderr.log", "image-audit.json", "graphics-manifest.json")]}
    result["ruby_reference_sha256"] = sha(ruby_reference_path)
    result["policy_reference_sha256"] = sha(policy_reference_path)
    result["wrap_reference_sha256"] = sha(wrap_reference_path)
    result["surface_reference_sha256"] = sha(surface_reference_path)
    result["text_reference_sha256"] = sha(text_reference_path)
    result["host_reference_sha256"] = sha(reference_path)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print("Native graphics: runtime text/ruby ownership, Flash preemption, reference pixels and complete heap recovery passed")


if __name__ == "__main__":
    main()
