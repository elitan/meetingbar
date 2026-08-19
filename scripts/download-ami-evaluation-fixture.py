#!/usr/bin/env python3
"""Download one deterministic, conversational AMI meeting fixture."""

import argparse
import json
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ElementTree
import zipfile
from pathlib import Path


MEETING_ID = "ES2005a"
CLIP_START_SECONDS = 78.75
CLIP_END_SECONDS = 113.20
ANNOTATIONS_URL = (
    "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/"
    "ami_public_manual_1.6.2.zip"
)
AUDIO_URL = (
    "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/"
    f"{MEETING_ID}/audio/{MEETING_ID}.Mix-Headset.wav"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "output",
        nargs="?",
        default="EvaluationFixtures/AMI",
        type=Path,
    )
    parser.add_argument("--cache-dir", type=Path)
    return parser.parse_args()


def download_if_missing(url: str, destination: Path) -> None:
    if destination.exists() and destination.stat().st_size > 0:
        return
    print(f"Downloading {url}")
    urllib.request.urlretrieve(url, destination)


def transcript_from_annotations(archive_path: Path) -> str:
    words: list[tuple[float, str, str]] = []
    with zipfile.ZipFile(archive_path) as archive:
        for speaker in ("A", "B", "C", "D"):
            member = f"words/{MEETING_ID}.{speaker}.words.xml"
            with archive.open(member) as file:
                root = ElementTree.parse(file).getroot()
            for element in root:
                if element.tag != "w" or element.attrib.get("punc") == "true":
                    continue
                text = (element.text or "").strip()
                start = float(element.attrib["starttime"])
                end = float(element.attrib["endtime"])
                if text and start >= CLIP_START_SECONDS and end <= CLIP_END_SECONDS:
                    words.append((start, speaker, text))
    words.sort()
    return " ".join(text for _, _, text in words)


def create_fixture(output: Path, cache: Path) -> None:
    annotations_path = cache / "meetingbar-ami-manual-1.6.2.zip"
    source_audio_path = cache / f"meetingbar-ami-{MEETING_ID}.wav"
    download_if_missing(ANNOTATIONS_URL, annotations_path)
    download_if_missing(AUDIO_URL, source_audio_path)

    fixture_id = f"{MEETING_ID}-conversation"
    relative_audio_path = Path("audio") / f"{fixture_id}.wav"
    destination = output / relative_audio_path
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            str(CLIP_START_SECONDS),
            "-i",
            str(source_audio_path),
            "-t",
            str(CLIP_END_SECONDS - CLIP_START_SECONDS),
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

    manifest = {
        "dataset": "AMI Meeting Corpus manual annotations 1.6.2",
        "license": "CC BY 4.0",
        "fixtures": [
            {
                "id": fixture_id,
                "language": "en_us",
                "audioPath": str(relative_audio_path),
                "reference": transcript_from_annotations(annotations_path),
                "maximumWER": 0.15,
            }
        ],
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (output / "ATTRIBUTION.txt").write_text(
        "AMI Meeting Corpus — AMI Consortium / University of Edinburgh\n"
        "https://groups.inf.ed.ac.uk/ami/corpus/\n"
        "Meeting ES2005a, Mix-Headset audio and manual word annotations\n"
        "License: Creative Commons Attribution 4.0 International\n",
        encoding="utf-8",
    )
    print(f"Wrote {fixture_id} to {output}")


def main() -> None:
    args = parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    temporary_cache = None
    if args.cache_dir is None:
        temporary_cache = tempfile.TemporaryDirectory(prefix="meetingbar-ami-")
        cache = Path(temporary_cache.name)
    else:
        cache = args.cache_dir.resolve()
        cache.mkdir(parents=True, exist_ok=True)

    create_fixture(output, cache)
    if temporary_cache is not None:
        temporary_cache.cleanup()


if __name__ == "__main__":
    main()
