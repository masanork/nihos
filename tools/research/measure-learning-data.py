#!/usr/bin/env python3
"""Host-only sizing probe for nihos learning content; never touches a device.

Downloads stay in ignored build/. Generated databases are experimental search
projections, not complete dictionary/viewer distribution packages.
"""

import argparse
import csv
import datetime
import gzip
import hashlib
import io
import json
import platform
import shutil
import sqlite3
import subprocess
import sys
import time
import unicodedata
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


SOURCES = {
    "JMdict_e.gz": "https://www.edrdg.org/pub/Nihongo/JMdict_e.gz",
    "kanjidic2.xml.gz": "https://www.edrdg.org/pub/Nihongo/kanjidic2.xml.gz",
    "aozora-catalog.zip": "https://www.aozora.gr.jp/index_pages/list_person_all_extended_utf8.zip",
}
BOOK_IDS = ("000789", "000773", "000456")


def fetch(url, target):
    if not target.exists():
        with urllib.request.urlopen(url, timeout=60) as response:
            with target.open("wb") as out:
                shutil.copyfileobj(response, out)


def fingerprint(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return {"bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def xml_records(path, tag):
    with gzip.open(path, "rb") as source:
        for event, elem in ET.iterparse(source, events=("start", "end")):
            if event == "start" and elem.tag in ("JMdict", "kanjidic2"):
                root = elem
            if event == "end" and elem.tag == tag:
                yield elem
                root.clear()


def normalized(term):
    return unicodedata.normalize("NFKC", term).casefold()


def make_base(name, rows, output):
    path = output / f"{name}-base.db"
    path.unlink(missing_ok=True)
    db = sqlite3.connect(path)
    db.executescript("""
        PRAGMA page_size=4096;
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        CREATE TABLE entries(id INTEGER PRIMARY KEY, headwords TEXT, readings TEXT, body TEXT);
        CREATE TABLE forms(term TEXT, entry_id INTEGER, kind TEXT);
    """)
    count = text_bytes = form_count = 0
    for rowid, headwords, readings, body in rows:
        db.execute("INSERT INTO entries VALUES(?,?,?,?)", (rowid, " / ".join(headwords), " / ".join(readings), body))
        forms = {(normalized(term), rowid, kind) for kind, terms in (("headword", headwords), ("reading", readings)) for term in terms}
        db.executemany("INSERT INTO forms VALUES(?,?,?)", sorted(forms))
        text_bytes += sum(len(value.encode("utf-8")) for value in (" / ".join(headwords), " / ".join(readings), body))
        form_count += len(forms)
        count += 1
    db.execute("CREATE INDEX form_lookup ON forms(term,entry_id)")
    db.commit()
    db.execute("VACUUM")
    db.close()
    return path, {"records": count, "forms": form_count, "projected_utf8_bytes": text_bytes}


def measure_queries(path, variant, bounded=False):
    # This is a warm host timing with a small SQLite cache, NOT target latency.
    db = sqlite3.connect(f"file:{path.resolve()}?mode=ro&immutable=1", uri=True)
    db.executescript("PRAGMA cache_size=-1024; PRAGMA mmap_size=0; PRAGMA temp_store=MEMORY;")
    if bounded:
        db.execute("PRAGMA hard_heap_limit=4194304")
    kanji = path.name.startswith("kanjidic")
    book = path.name.startswith("aozora")
    queries = {"exact": ("SELECT entry_id FROM forms WHERE term=? LIMIT 20", (normalized("水" if kanji else "日本"),))}
    if variant != "base":
        match = '"water"' if kanji and variant == "unicode61-full" else ('"wat"' if kanji else '"日本語"')
        queries["match"] = ("SELECT rowid FROM search WHERE search MATCH ? LIMIT 20", (match,))
        if variant == "trigram-none":
            column = "body" if book or kanji else "headwords"
            queries["substring"] = (f"SELECT rowid FROM search WHERE {column} LIKE ? LIMIT 20", ("%wat%" if kanji else "%日本語%",))
        else:
            queries["ranked"] = ("SELECT rowid FROM search WHERE search MATCH ? ORDER BY rank LIMIT 20", (match,))
    result = {}
    for key, (sql, params) in queries.items():
        try:
            rows = db.execute(sql, params).fetchall()
            samples = []
            for _ in range(7):
                start = time.perf_counter()
                db.execute(sql, params).fetchall()
                samples.append((time.perf_counter() - start) * 1000)
            result[key] = {"returned_rows": len(rows), "warm_median_ms": sorted(samples)[len(samples) // 2]}
        except (sqlite3.OperationalError, MemoryError) as exc:
            result[key] = {"error": str(exc)}
    db.close()
    return {"sqlite_heap_limit_bytes": 4194304 if bounded else None, "queries": result}


def budget_worker(path, variant):
    proc = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--read-budget", str(path), "--variant", variant], capture_output=True, text=True, check=True)
    return json.loads(proc.stdout)


def variants(base, output):
    result = [{"variant": "base", "database_bytes": base.stat().st_size, "read_probe": budget_worker(base, "base")}]
    for variant, tokenizer, options in (
        ("unicode61-full", "unicode61", "detail=full"),
        ("trigram-full", "trigram", "detail=full"),
        ("trigram-none", "trigram", "detail=none,columnsize=0"),
    ):
        path = output / base.name.replace("-base.db", f"-{variant}.db")
        shutil.copyfile(base, path)
        db = sqlite3.connect(path)
        db.executescript("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;")
        start = time.perf_counter()
        db.execute(f"CREATE VIRTUAL TABLE search USING fts5(headwords,readings,body,content='entries',content_rowid='id',tokenize='{tokenizer}',{options})")
        db.execute("INSERT INTO search(search) VALUES('rebuild')")
        db.execute("INSERT INTO search(search) VALUES('optimize')")
        db.execute("INSERT INTO search(search,rank) VALUES('integrity-check',1)")
        db.commit()
        db.execute("VACUUM")
        elapsed = time.perf_counter() - start
        db.close()
        result.append({"variant": variant, "database_bytes": path.stat().st_size, "host_build_seconds": elapsed, "read_probe": budget_worker(path, variant)})
        print(base.stem, variant, path.stat().st_size, flush=True)
    return result


def jmdict(path):
    for entry in xml_records(path, "entry"):
        headwords = [item.text for item in entry.findall("k_ele/keb") if item.text]
        readings = [item.text for item in entry.findall("r_ele/reb") if item.text]
        # Sizing projection: senses/restrictions/POS are deliberately not serialized.
        glosses = [item.text for item in entry.findall("sense/gloss") if item.text]
        yield int(entry.findtext("ent_seq")), headwords, readings, "; ".join(glosses)


def kanjidic(path):
    for index, entry in enumerate(xml_records(path, "character"), 1):
        readings = [item.text for item in entry.findall("reading_meaning/rmgroup/reading") if item.attrib.get("r_type", "").startswith("ja_") and item.text]
        meanings = [item.text for item in entry.findall("reading_meaning/rmgroup/meaning") if "m_lang" not in item.attrib and item.text]
        yield index, [entry.findtext("literal")], readings, "; ".join(meanings)


def aozora(data):
    with zipfile.ZipFile(data / "aozora-catalog.zip") as archive:
        csv_bytes = archive.read(archive.namelist()[0])
    catalog = list(csv.DictReader(io.StringIO(csv_bytes.decode("utf-8-sig"))))
    unique = {row["作品ID"]: row for row in catalog}
    selected = []
    passages = []
    for work_id in BOOK_IDS:
        row = unique[work_id]
        if row["作品著作権フラグ"] != "なし":
            raise ValueError(f"Work is not flagged public-domain: {work_id}")
        url = row["テキストファイルURL"]
        target = data / f"aozora-{work_id}.zip"
        fetch(url, target)
        with zipfile.ZipFile(target) as archive:
            name = next(name for name in archive.namelist() if name.lower().endswith(".txt"))
            # Keep annotations and colophon in this sizing probe. A real viewer
            # needs structured ruby/gaiji handling and separate search text.
            text = archive.read(name).decode("cp932")
        selected.append({"work_id": work_id, "title": row["作品名"], "url": url, "utf8_bytes": len(text.encode("utf-8")), **fingerprint(target)})
        # Fixed character chunks are a sizing convenience, not final passage IDs.
        for offset in range(0, len(text), 1024):
            passages.append((len(passages) + 1, [], [], text[offset:offset + 1024]))
    return passages, {"catalog_rows": len(catalog), "catalog_unique_works": len(unique), "selected_books": selected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("build/app-study"))
    parser.add_argument("--read-budget", type=Path)
    parser.add_argument("--variant", default="base")
    args = parser.parse_args()
    if args.read_budget:
        print(json.dumps(measure_queries(args.read_budget, args.variant, bounded=True)))
        return
    data, output = args.root / "downloads", args.root / "databases"
    data.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    for name, url in SOURCES.items():
        fetch(url, data / name)
    report = {
        "evidence": "host-only sizing; not ESP32-P4 latency or heap qualification",
        "recorded_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "host": {"platform": platform.platform(), "machine": platform.machine()},
        "sqlite_version": sqlite3.sqlite_version,
        "page_size": 4096,
        "query_cache_kib": 1024,
        "mmap_size": 0,
        "build_mode": "host journal_mode=OFF,synchronous=OFF; never for user writes",
        "dictionary_projection": "all entries, headwords, readings, English gloss only; not a lossless dictionary pack",
        "sources": {name: {"url": url, **fingerprint(data / name)} for name, url in SOURCES.items()},
        "corpora": {},
    }
    for name, rows in (("jmdict", jmdict(data / "JMdict_e.gz")), ("kanjidic", kanjidic(data / "kanjidic2.xml.gz"))):
        base, info = make_base(name, rows, output)
        info["variants"] = variants(base, output)
        report["corpora"][name] = info
    rows, metadata = aozora(data)
    base, info = make_base("aozora-three", rows, output)
    info.update(metadata)
    info["variants"] = variants(base, output)
    report["corpora"]["aozora-three"] = info
    path = args.root / "results.json"
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("Report:", path)


if __name__ == "__main__":
    main()
