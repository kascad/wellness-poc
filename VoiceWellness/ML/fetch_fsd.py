"""Fetch a reproducible, license-filtered FSD50K evaluation subset."""
import concurrent.futures
import csv
import io
from http.client import IncompleteRead
import json
from pathlib import Path
import random
import struct
import time
import sys
import urllib.request
import zipfile
import zlib

ROOT = Path(sys.argv[1])
OUT = ROOT / "fsd"
OUT.mkdir(exist_ok=True)
BASE = "https://zenodo.org/api/records/4060432/files/"
PARTS = ["FSD50K.eval_audio.z01", "FSD50K.eval_audio.zip"]
SIZES = [3221225472, 3037675767]


def get_range(disk, start, count):
    end = start + count - 1
    request = urllib.request.Request(
        f"{BASE}{PARTS[disk]}/content?part={start}",
        headers={"Range": f"bytes={start}-{end}"},
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                if response.status != 206:
                    raise ValueError("Server did not honor byte range")
                data = response.read()
                if len(data) != count:
                    raise ValueError("Incomplete ZIP segment")
                return data
        except (OSError, ValueError, IncompleteRead):
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)


def read_split(disk, start, count):
    if start >= SIZES[disk]:
        return read_split(disk + 1, start - SIZES[disk], count)
    first = min(count, SIZES[disk] - start)
    data = get_range(disk, start, first)
    return data if first == count else data + read_split(disk + 1, 0, count - first)


def zip_index():
    tail = get_range(1, SIZES[1] - 65557, 65557)
    footer = tail.rfind(b"PK\x05\x06")
    _, _, disk, _, _, size, offset, _ = struct.unpack_from("<4s4H2LH", tail, footer)
    directory = read_split(disk, offset, size)
    index = {}
    cursor = 0
    while cursor < len(directory):
        fields = struct.unpack_from("<4s6H3I5H2I", directory, cursor)
        signature, *rest = fields
        if signature != b"PK\x01\x02":
            raise ValueError("Invalid ZIP central entry")
        method, crc, length = fields[4], fields[7], fields[8]
        name_len, extra_len, comment_len, disk = fields[10:14]
        name = directory[cursor + 46 : cursor + 46 + name_len].decode()
        index[Path(name).stem] = (disk, fields[-1], length, crc, method)
        cursor += 46 + name_len + extra_len + comment_len
    return index


def fetch(row):
    identifier = row["fname"]
    path = OUT / f"{identifier}.wav"
    if not path.exists():
        disk, offset, size, crc, method = index[identifier]
        header = read_split(disk, offset, 30)
        name_len, extra_len = struct.unpack_from("<HH", header, 26)
        compressed = read_split(disk, offset + 30 + name_len + extra_len, size)
        raw = zlib.decompress(compressed, -15) if method == 8 else compressed
        if zlib.crc32(raw) != crc:
            raise ValueError("Invalid ZIP CRC")
        path.write_bytes(raw)
    return row


if __name__ == "__main__":
    with zipfile.ZipFile(ROOT / "fsd_truth.zip") as archive:
        rows = list(csv.DictReader(io.StringIO(archive.read("FSD50K.ground_truth/eval.csv").decode())))
    with zipfile.ZipFile(ROOT / "fsd_meta.zip") as archive:
        meta = json.loads(archive.read("FSD50K.metadata/eval_clips_info_FSD50K.json"))

    for row in rows:
        info = meta[row["fname"]]
        row["license"] = info["license"]
        row["uploader"] = info["uploader"]
        row["title"] = info["title"]
    licensed = [row for row in rows if "/licenses/by/" in row["license"] or "/publicdomain/zero/" in row["license"]]
    positive = [row for row in licensed if "Cough" in row["labels"].split(",")]
    negative = [row for row in licensed if "Cough" not in row["labels"].split(",")]
    rng = random.Random(26)
    speech = [row for row in negative if "Speech" in row["labels"].split(",")]
    other = [row for row in negative if row not in speech]
    plan = positive + rng.sample(speech, min(45, len(speech))) + rng.sample(other, 45)

    index = zip_index()
    with (ROOT / "fsd_subset.csv").open("w", newline="") as manifest:
        writer = csv.DictWriter(manifest, fieldnames=list(rows[0]))
        writer.writeheader()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = {pool.submit(fetch, row): row for row in plan}
            results = {}
            for future in concurrent.futures.as_completed(futures):
                try:
                    row = future.result()
                    results[row["fname"]] = row
                except (OSError, ValueError, IncompleteRead) as exc:
                    print(f'Skipped {futures[future]["fname"]}: {exc}', file=sys.stderr)
                manifest.seek(0)
                manifest.truncate()
                writer.writeheader()
                writer.writerows(results[row["fname"]] for row in plan if row["fname"] in results)
                manifest.flush()
    print(f"FSD50K: {len(positive)} positive, {len(plan)-len(positive)} negative")
