#!/usr/bin/env python3
"""Download a small, deterministic FLEURS ASR evaluation set."""

import argparse
import csv
import json
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path


DATASET = "google/fleurs"
LICENSE = "CC BY 4.0"
BASE_URL = "https://huggingface.co/datasets/google/fleurs/resolve/main/data"
LANGUAGES = ("sv_se", "en_us")
SAMPLE_COUNT = 5


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "output",
        nargs="?",
        default="EvaluationFixtures/FLEURS",
        type=Path,
    )
    parser.add_argument("--cache-dir", type=Path)
    return parser.parse_args()


def download_if_missing(url: str, destination: Path) -> None:
    if destination.exists() and destination.stat().st_size > 0:
        return
    print(f"Downloading {url}")
    urllib.request.urlretrieve(url, destination)


def selected_rows(tsv_path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen_sentence_ids: set[str] = set()
    with tsv_path.open(encoding="utf-8", newline="") as file:
        for columns in csv.reader(file, delimiter="\t"):
            if len(columns) < 4 or columns[0] in seen_sentence_ids:
                continue
            seen_sentence_ids.add(columns[0])
            rows.append(
                {
                    "sentence_id": columns[0],
                    "file_name": columns[1],
                    "reference": columns[3],
                }
            )
            if len(rows) == SAMPLE_COUNT:
                break
    if len(rows) != SAMPLE_COUNT:
        raise RuntimeError(f"Expected {SAMPLE_COUNT} distinct FLEURS sentences")
    return rows


def extract_language(language: str, output: Path, cache: Path) -> list[dict[str, object]]:
    short_language = language.split("_", maxsplit=1)[0]
    archive_path = cache / f"meetingbar-fleurs-{short_language}-dev.tar.gz"
    tsv_path = cache / f"meetingbar-fleurs-{short_language}-dev.tsv"
    download_if_missing(f"{BASE_URL}/{language}/audio/dev.tar.gz", archive_path)
    download_if_missing(f"{BASE_URL}/{language}/dev.tsv", tsv_path)
    rows = selected_rows(tsv_path)
    fixtures: list[dict[str, object]] = []

    with tarfile.open(archive_path, "r:gz") as archive:
        for index, row in enumerate(rows):
            fixture_id = f"{language}-{index:04d}"
            relative_path = Path("audio") / f"{fixture_id}.wav"
            destination = output / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            member = archive.getmember(f"dev/{row['file_name']}")
            extracted = archive.extractfile(member)
            if extracted is None:
                raise RuntimeError(f"Could not extract {member.name}")

            with tempfile.NamedTemporaryFile(suffix=".wav") as source:
                shutil.copyfileobj(extracted, source)
                source.flush()
                subprocess.run(
                    [
                        "ffmpeg",
                        "-hide_banner",
                        "-loglevel",
                        "error",
                        "-y",
                        "-i",
                        source.name,
                        "-ac",
                        "1",
                        "-ar",
                        "16000",
                        "-c:a",
                        "pcm_s16le",
                        str(destination),
                    ],
                    check=True,
                )

            fixtures.append(
                {
                    "id": fixture_id,
                    "language": language,
                    "audioPath": str(relative_path),
                    "reference": row["reference"],
                    "maximumWER": None,
                }
            )

    return fixtures


def write_manifest(output: Path, fixtures: list[dict[str, object]]) -> None:
    manifest = {
        "dataset": f"{DATASET} dev",
        "license": LICENSE,
        "fixtures": fixtures,
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (output / "ATTRIBUTION.txt").write_text(
        "Google FLEURS — Few-shot Learning Evaluation of Universal "
        "Representations of Speech\n"
        "https://huggingface.co/datasets/google/fleurs\n"
        "License: Creative Commons Attribution 4.0 International\n",
        encoding="utf-8",
    )


def main() -> None:
    args = parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    temporary_cache = None
    if args.cache_dir is None:
        temporary_cache = tempfile.TemporaryDirectory(prefix="meetingbar-fleurs-")
        cache = Path(temporary_cache.name)
    else:
        cache = args.cache_dir.resolve()
        cache.mkdir(parents=True, exist_ok=True)

    fixtures: list[dict[str, object]] = []
    for language in LANGUAGES:
        fixtures.extend(extract_language(language, output, cache))
    write_manifest(output, fixtures)
    print(f"Wrote {len(fixtures)} fixtures to {output}")
    if temporary_cache is not None:
        temporary_cache.cleanup()


if __name__ == "__main__":
    main()
