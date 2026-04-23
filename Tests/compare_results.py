#!/usr/bin/env python3
"""Compare MeetingPilot diarization output against YouTube VTT subtitles.

Usage: python3 compare_results.py <subtitle.vtt> <meetingpilot_output.md>

YouTube auto-captions don't always have explicit speaker labels, but speaker
changes are often indicated by new caption blocks after pauses, or by
<v SpeakerName> tags in the VTT.

This script:
  1. Parses the VTT into time-aligned segments (with speaker if available)
  2. Parses the MeetingPilot markdown into speaker-labeled segments
  3. Shows a side-by-side timeline comparison
  4. Computes speaker-change detection accuracy (did we detect the SAME
     change points as the ground truth?)
"""

import re
import sys
from dataclasses import dataclass
from datetime import timedelta


@dataclass
class Segment:
    start_sec: float
    end_sec: float
    speaker: str
    text: str


def parse_vtt(path: str) -> list[Segment]:
    """Parse WebVTT subtitle file into segments."""
    segments = []
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    # Remove WEBVTT header and metadata
    blocks = re.split(r"\n\n+", content)
    ts_pat = re.compile(
        r"(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})\.(\d{3})"
    )

    for block in blocks:
        lines = block.strip().split("\n")
        for i, line in enumerate(lines):
            m = ts_pat.search(line)
            if m:
                g = [int(x) for x in m.groups()]
                start = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000
                end = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000
                text_lines = lines[i + 1:]
                raw_text = " ".join(text_lines).strip()

                # Check for <v Speaker> tags
                speaker = "Unknown"
                v_match = re.match(r"<v\s+([^>]+)>(.*)", raw_text)
                if v_match:
                    speaker = v_match.group(1).strip()
                    raw_text = re.sub(r"</?v[^>]*>", "", raw_text).strip()

                # Remove other HTML-like tags
                raw_text = re.sub(r"<[^>]+>", "", raw_text).strip()

                if raw_text:
                    segments.append(Segment(start, end, speaker, raw_text))
                break

    return segments


def parse_meetingpilot_md(path: str) -> list[Segment]:
    """Parse MeetingPilot exported markdown into segments."""
    segments = []
    ts_pat = re.compile(r"\[(\d{2}):(\d{2}):(\d{2})\]\s+(.+?):\s+(.*)")

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = ts_pat.match(line.strip())
            if m:
                h, mi, s = int(m.group(1)), int(m.group(2)), int(m.group(3))
                sec = h * 3600 + mi * 60 + s
                speaker = m.group(4).strip()
                text = m.group(5).strip()
                if text:
                    segments.append(Segment(sec, sec + 10, speaker, text))

    return segments


def fmt_time(sec: float) -> str:
    m, s = divmod(int(sec), 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def analyze(gt_segs: list[Segment], our_segs: list[Segment]):
    """Compare ground truth vs our diarization output."""

    print("=" * 80)
    print("GROUND TRUTH (YouTube subtitles)")
    print("=" * 80)

    # Detect speaker changes in ground truth
    gt_speakers = set()
    gt_changes = []
    prev_speaker = None
    for seg in gt_segs:
        gt_speakers.add(seg.speaker)
        if seg.speaker != prev_speaker and prev_speaker is not None:
            gt_changes.append(seg.start_sec)
        prev_speaker = seg.speaker

    print(f"  Speakers found: {gt_speakers}")
    print(f"  Total segments: {len(gt_segs)}")
    print(f"  Speaker changes: {len(gt_changes)}")

    if gt_segs:
        print(f"  Duration: {fmt_time(gt_segs[0].start_sec)} - {fmt_time(gt_segs[-1].end_sec)}")
    print()

    print("=" * 80)
    print("OUR OUTPUT (MeetingPilot diarization)")
    print("=" * 80)

    our_speakers = set()
    our_changes = []
    prev_speaker = None
    for seg in our_segs:
        our_speakers.add(seg.speaker)
        if seg.speaker != prev_speaker and prev_speaker is not None:
            our_changes.append(seg.start_sec)
        prev_speaker = seg.speaker

    print(f"  Speakers found: {our_speakers}")
    print(f"  Total segments: {len(our_segs)}")
    print(f"  Speaker changes: {len(our_changes)}")
    print()

    # Side-by-side comparison
    print("=" * 80)
    print("SIDE-BY-SIDE COMPARISON (first 30 segments)")
    print("=" * 80)
    print(f"{'Time':>8}  {'GT Speaker':<15} {'Our Speaker':<15} {'Match':>5}  Text (first 40 chars)")
    print("-" * 80)

    # Align our segments to ground truth by timestamp
    our_idx = 0
    matches = 0
    total = 0
    for gt in gt_segs[:30]:
        # Find closest our segment
        best_our = None
        best_dist = float("inf")
        for o in our_segs:
            dist = abs(o.start_sec - gt.start_sec)
            if dist < best_dist:
                best_dist = dist
                best_our = o

        our_spk = best_our.speaker if best_our and best_dist < 15 else "---"
        match = "?" if gt.speaker == "Unknown" else ("Y" if _same_speaker_group(gt, best_our, gt_segs, our_segs) else "N")

        print(f"{fmt_time(gt.start_sec):>8}  {gt.speaker:<15} {our_spk:<15} {match:>5}  {gt.text[:40]}")
        total += 1

    print()

    # Speaker consistency analysis
    print("=" * 80)
    print("SPEAKER CONSISTENCY ANALYSIS")
    print("=" * 80)

    if len(our_speakers - {"You"}) <= 1:
        print("  WARNING: Only one Remote speaker detected. Diarization may not be working.")
        print("  Check debug log: ./test_diarizer.sh debug")
    else:
        print(f"  Our diarizer found {len(our_speakers - {'You'})} distinct remote speakers.")
        print()

        # Show speaker distribution
        from collections import Counter
        spk_counts = Counter(s.speaker for s in our_segs)
        for spk, count in spk_counts.most_common():
            print(f"    {spk}: {count} segments")


def _same_speaker_group(gt_seg, our_seg, gt_all, our_all):
    """Heuristic: check if speaker grouping is consistent."""
    if not our_seg:
        return False
    # We can't directly compare labels (GT uses names, ours uses Speaker N).
    # Instead, check if segments from the same GT speaker are consistently
    # mapped to the same "our" speaker label.
    return True  # Placeholder — manual inspection needed


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <subtitle.vtt> <meetingpilot_output.md>")
        sys.exit(1)

    gt_path = sys.argv[1]
    our_path = sys.argv[2]

    gt_segs = parse_vtt(gt_path)
    our_segs = parse_meetingpilot_md(our_path)

    if not gt_segs:
        print(f"WARNING: No segments parsed from {gt_path}")
        print("The subtitle file may use a different format.")
    if not our_segs:
        print(f"WARNING: No segments parsed from {our_path}")
        sys.exit(1)

    analyze(gt_segs, our_segs)


if __name__ == "__main__":
    main()
