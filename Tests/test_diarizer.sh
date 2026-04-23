#!/bin/bash
# Fully automated speaker diarization test.
#
# Usage:
#   ./test_diarizer.sh                                    # Synthetic TTS audio
#   ./test_diarizer.sh <youtube_url> [--duration <sec>]    # YouTube video
#   ./test_diarizer.sh <local.wav>                         # Local WAV file
#
# Extra options (append after other args):
#   --threshold <float>   Override merge distance threshold (default: 0.12)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR/test_data"
AUDIO_FILE="$TEST_DIR/test_audio.wav"
GT_FILE="$TEST_DIR/ground_truth.txt"
SAMPLE_RATE=16000

THRESHOLD=""
DURATION_ARG=""

# Parse extra options from the end of args
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --duration) DURATION_ARG="$2"; shift 2 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

mkdir -p "$TEST_DIR"

echo "================================================================"
echo "  AUTOMATED SPEAKER DIARIZATION TEST"
echo "================================================================"
echo ""

# ── Step 1: Prepare audio ──────────────────────────────────────────

if [ $# -eq 0 ]; then
    echo "[1/3] Generating two-speaker TTS audio (Daniel + Samantha)..."
    python3 "$SCRIPT_DIR/generate_test_audio.py"
    echo ""

elif [[ "$1" == http* ]]; then
    URL="$1"
    echo "[1/3] Downloading audio from YouTube..."
    echo "      URL: $URL"

    # Remove stale TTS ground truth so it won't be used for YouTube comparison
    rm -f "$GT_FILE"

    yt-dlp -x --audio-format wav \
           --no-playlist \
           -o "$TEST_DIR/raw_audio.%(ext)s" \
           "$URL" 2>&1 | grep -E "Destination|Download|ERROR" || true

    # Also try to download auto-generated subtitles as ground truth
    yt-dlp --write-auto-sub --sub-lang en \
           --skip-download --no-playlist \
           -o "$TEST_DIR/yt_subs" \
           "$URL" 2>/dev/null || true

    if [ -f "$TEST_DIR/raw_audio.wav" ]; then
        FFMPEG_OPTS="-y -i $TEST_DIR/raw_audio.wav -ar $SAMPLE_RATE -ac 1"
        [ -n "$DURATION_ARG" ] && FFMPEG_OPTS="$FFMPEG_OPTS -t $DURATION_ARG"
        eval "ffmpeg $FFMPEG_OPTS $AUDIO_FILE 2>/dev/null"
    else
        echo "ERROR: Download failed. Try: yt-dlp --cookies-from-browser chrome ..."
        exit 1
    fi
    echo ""

else
    echo "[1/3] Converting local file to 16kHz mono..."
    rm -f "$GT_FILE"
    ffmpeg -y -i "$1" -ar $SAMPLE_RATE -ac 1 "$AUDIO_FILE" 2>/dev/null
    echo ""
fi

if [ ! -f "$AUDIO_FILE" ]; then
    echo "ERROR: No audio file at $AUDIO_FILE"
    exit 1
fi
DUR=$(ffprobe -v error -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 "$AUDIO_FILE" 2>/dev/null)
echo "      Audio: ${DUR}s ($(du -h "$AUDIO_FILE" | cut -f1))"
echo ""

# ── Step 2: Build & run diarizer ───────────────────────────────────

echo "[2/3] Building and running DiarizeTest..."
cd "$PROJECT_DIR"
swift build --product DiarizeTest 2>&1 | grep -E "Build complete|error:" || true

DIARIZE_BIN=$(swift build --product DiarizeTest --show-bin-path 2>/dev/null)/DiarizeTest
[ ! -x "$DIARIZE_BIN" ] && echo "ERROR: Binary not found" && exit 1

DIARIZE_ARGS="$AUDIO_FILE"
[ -n "$THRESHOLD" ] && DIARIZE_ARGS="$DIARIZE_ARGS --threshold $THRESHOLD"

echo ""
RESULT_FILE="$TEST_DIR/diarize_output.txt"
$DIARIZE_BIN $DIARIZE_ARGS 2>&1 | tee "$RESULT_FILE"
echo ""

# ── Step 3: Compare with ground truth ─────────────────────────────

echo "[3/3] Accuracy Analysis"
echo ""

if [ -f "$GT_FILE" ]; then
    python3 - "$GT_FILE" "$RESULT_FILE" "$SAMPLE_RATE" <<'PYEOF'
import re, sys

gt_path, result_path, sr = sys.argv[1], sys.argv[2], int(sys.argv[3])

# Parse ground truth: [MM:SS-MM:SS] Speaker_X
gt_segs = []
with open(gt_path) as f:
    for line in f:
        m = re.match(r'\[(\d+):(\d+)-(\d+):(\d+)\]\s+(\S+)', line.strip())
        if m:
            start = int(m.group(1)) * 60 + int(m.group(2))
            end = int(m.group(3)) * 60 + int(m.group(4))
            gt_segs.append({"start": start, "end": end, "speaker": m.group(5)})

# Parse diarizer segment output: MM:SS   MM:SS   Xs   Speaker N
our_segs = []
with open(result_path) as f:
    for line in f:
        m = re.match(r'\s*(\d+):(\d+)\s+(\d+):(\d+)\s+[\d.]+s\s+(Speaker \d+)', line.strip())
        if m:
            start = int(m.group(1)) * 60 + int(m.group(2))
            end = int(m.group(3)) * 60 + int(m.group(4))
            our_segs.append({"start": start, "end": end, "speaker": m.group(5)})

if not gt_segs or not our_segs:
    print("  Cannot compare: missing ground truth or diarizer output")
    sys.exit(0)

gt_speakers = sorted(set(s["speaker"] for s in gt_segs))
our_speakers = sorted(set(s["speaker"] for s in our_segs))
print(f"  Ground truth: {len(gt_segs)} segments, {len(gt_speakers)} speakers {gt_speakers}")
print(f"  Detected:     {len(our_segs)} segments, {len(our_speakers)} speakers {our_speakers}")
print()

# Per-second evaluation: for each second, what's the GT speaker and detected speaker?
total_sec = max(max(s["end"] for s in gt_segs), max(s["end"] for s in our_segs)) + 1

def speaker_at(segs, t):
    for s in segs:
        if s["start"] <= t < s["end"]:
            return s["speaker"]
    return None

# Build mapping by counting overlap at each second
mapping_counts = {}  # our_spk -> {gt_spk: count}
for t in range(total_sec):
    gt_spk = speaker_at(gt_segs, t)
    our_spk = speaker_at(our_segs, t)
    if gt_spk and our_spk:
        if our_spk not in mapping_counts:
            mapping_counts[our_spk] = {}
        mapping_counts[our_spk][gt_spk] = mapping_counts[our_spk].get(gt_spk, 0) + 1

# Best mapping (our → gt) by majority
best_map = {}
for our_spk, gt_dict in mapping_counts.items():
    best_gt = max(gt_dict, key=gt_dict.get)
    best_map[our_spk] = best_gt

print("  Speaker mapping (detected → ground truth):")
for our_spk in sorted(best_map):
    gt_dict = mapping_counts[our_spk]
    total = sum(gt_dict.values())
    correct = gt_dict.get(best_map[our_spk], 0)
    pct = 100 * correct / total if total else 0
    print(f"    {our_spk:>12} → {best_map[our_spk]:<12} ({correct}/{total}s = {pct:.0f}% purity)")

# Overall per-second accuracy
correct = 0
total_eval = 0
for t in range(total_sec):
    gt_spk = speaker_at(gt_segs, t)
    our_spk = speaker_at(our_segs, t)
    if gt_spk and our_spk:
        total_eval += 1
        if best_map.get(our_spk) == gt_spk:
            correct += 1

accuracy = 100 * correct / total_eval if total_eval else 0
print()
print(f"  ╔══════════════════════════════════════════╗")
print(f"  ║  PER-SECOND ACCURACY: {correct}/{total_eval}s = {accuracy:.1f}%     ║")
print(f"  ╚══════════════════════════════════════════╝")

# Speaker change recall
gt_changes = []
prev = None
for s in gt_segs:
    if s["speaker"] != prev:
        gt_changes.append(s["start"])
    prev = s["speaker"]

our_changes = []
prev = None
for s in our_segs:
    if s["speaker"] != prev:
        our_changes.append(s["start"])
    prev = s["speaker"]

caught = 0
for gt_t in gt_changes:
    for our_t in our_changes:
        if abs(gt_t - our_t) <= 3:
            caught += 1
            break

if gt_changes:
    recall = 100 * caught / len(gt_changes)
    print(f"\n  Speaker changes: GT={len(gt_changes)}, detected={len(our_changes)}")
    print(f"  Change detection recall: {caught}/{len(gt_changes)} = {recall:.0f}% (±3s)")

PYEOF
else
    echo "  No ground truth file — showing diarization quality metrics only."
    echo ""
    python3 - "$RESULT_FILE" <<'PYEOF2'
import re, sys

result_path = sys.argv[1]

# Parse diarizer segment output
segs = []
with open(result_path) as f:
    for line in f:
        m = re.match(r'\s*(\d+):(\d+)\s+(\d+):(\d+)\s+([\d.]+)s\s+(Speaker \d+)', line.strip())
        if m:
            start = int(m.group(1)) * 60 + int(m.group(2))
            end = int(m.group(3)) * 60 + int(m.group(4))
            dur = float(m.group(5))
            segs.append({"start": start, "end": end, "dur": dur, "speaker": m.group(6)})

if not segs:
    print("  No segments found in output.")
    sys.exit(0)

speakers = {}
for s in segs:
    spk = s["speaker"]
    if spk not in speakers:
        speakers[spk] = {"count": 0, "dur": 0.0}
    speakers[spk]["count"] += 1
    speakers[spk]["dur"] += s["dur"]

total_dur = sum(v["dur"] for v in speakers.values())

# Speaker changes
changes = 0
prev = None
for s in segs:
    if s["speaker"] != prev:
        changes += 1
    prev = s["speaker"]

print(f"  Total audio with speech: {total_dur:.1f}s across {len(segs)} segments")
print(f"  Speaker changes detected: {changes}")
print(f"  Speakers found: {len(speakers)}")
print()

for spk in sorted(speakers, key=lambda k: speakers[k]["dur"], reverse=True):
    info = speakers[spk]
    pct = 100 * info["dur"] / total_dur if total_dur else 0
    print(f"    {spk}: {info['dur']:.1f}s ({pct:.0f}%) in {info['count']} segments")

# Quality check
dominant = max(speakers.values(), key=lambda v: v["dur"])
dom_pct = 100 * dominant["dur"] / total_dur
print()
if len(speakers) <= 1:
    print("  ⚠ Only 1 speaker detected. Try lowering --threshold (e.g. 0.20, 0.25, 0.30)")
elif dom_pct > 90:
    print(f"  ⚠ Dominant speaker has {dom_pct:.0f}% of audio. Try raising --threshold (e.g. 0.20, 0.25)")
elif dom_pct > 70 and len(speakers) > 4:
    print(f"  ⚠ Over-segmentation likely ({len(speakers)} speakers). Try lowering --threshold")
else:
    print(f"  ✓ Reasonable speaker distribution detected")

PYEOF2
fi

echo ""
echo "================================================================"
echo "  TEST COMPLETE"
echo "================================================================"
