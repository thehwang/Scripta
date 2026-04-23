#!/usr/bin/env python3
"""Generate a two-speaker test audio using macOS TTS voices.

Uses 'say' command with different voices (Alex and Samantha) to create
realistic multi-speaker audio for testing the diarizer.

Output: test_data/test_audio.wav + test_data/ground_truth.txt
"""

import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "test_data")
SAMPLE_RATE = 16000
FINAL_WAV = os.path.join(OUTPUT_DIR, "test_audio.wav")
GT_FILE = os.path.join(OUTPUT_DIR, "ground_truth.txt")


# Conversation segments: (voice, text)
# Voices are filled in at runtime based on availability.
# "A" = voice_a (male), "B" = voice_b (female)
SCRIPT_LINES = [
    ("A", "Good morning everyone. Let's start by reviewing last week's progress on the project."),
    ("B", "Sure. The front end team completed the new dashboard design. We had some delays with the API integration though."),
    ("A", "What caused the delays? Was it a technical issue or a resource problem?"),
    ("B", "It was mainly a technical issue. The authentication service had some unexpected breaking changes that we needed to work around."),
    ("A", "I see. How much additional time do you think we'll need to finish the integration?"),
    ("B", "We estimate about three more days. The team is already working on the workaround and making good progress."),
    ("A", "That's reasonable. Let's make sure to add some buffer time for testing. I don't want us to rush the quality assurance process."),
    ("B", "Agreed. I'll update the timeline and share it with the team after this meeting."),
    ("A", "Great. Now let's move on to the budget review. We're currently at seventy five percent of our quarterly budget."),
    ("B", "That seems a bit high for this point in the quarter. Should we look at cutting some non essential expenses?"),
]


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Check available voices
    result = subprocess.run(["say", "-v", "?"], capture_output=True, text=True)
    available = result.stdout

    voice_a = "Daniel"
    voice_b = "Samantha"

    if "Daniel" not in available:
        voice_a = "Fred"
    if "Samantha" not in available:
        voice_b = "Karen"

    print(f"Using voices: {voice_a} (Speaker A) and {voice_b} (Speaker B)")

    # Generate individual segments as AIFF files
    segment_files = []
    silence_file = os.path.join(OUTPUT_DIR, "silence.wav")

    # Create 1-second silence
    subprocess.run([
        "ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
        "-t", "1.0", silence_file
    ], capture_output=True)

    gt_lines = []
    concat_list = os.path.join(OUTPUT_DIR, "concat.txt")

    voice_map = {"A": voice_a, "B": voice_b}

    with open(concat_list, "w") as cl:
        cumulative_sec = 0.0

        for i, (role, text) in enumerate(SCRIPT_LINES):
            voice = voice_map[role]
            seg_aiff = os.path.join(OUTPUT_DIR, f"seg_{i}.aiff")
            seg_wav = os.path.join(OUTPUT_DIR, f"seg_{i}.wav")

            print(f"  Generating segment {i}: [{voice}] {text[:50]}...")
            subprocess.run(
                ["say", "-v", voice, "-o", seg_aiff, text],
                check=True
            )

            # Convert to 16kHz mono WAV
            subprocess.run([
                "ffmpeg", "-y", "-i", seg_aiff,
                "-ar", str(SAMPLE_RATE), "-ac", "1",
                "-acodec", "pcm_s16le",
                seg_wav
            ], capture_output=True, check=True)

            # Get duration
            probe = subprocess.run([
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                seg_wav
            ], capture_output=True, text=True)
            duration = float(probe.stdout.strip())

            speaker = "Speaker_A" if voice == voice_a else "Speaker_B"
            start_sec = cumulative_sec
            end_sec = start_sec + duration

            m1, s1 = divmod(int(start_sec), 60)
            m2, s2 = divmod(int(end_sec), 60)
            gt_lines.append(f"[{m1:02d}:{s1:02d}-{m2:02d}:{s2:02d}] {speaker}")

            cl.write(f"file '{seg_wav}'\n")
            cl.write(f"file '{silence_file}'\n")

            cumulative_sec = end_sec + 1.0  # 1s silence gap
            segment_files.extend([seg_wav, silence_file])

            # Clean up AIFF
            os.remove(seg_aiff)

    # Concatenate all segments
    print("\nConcatenating segments...")
    subprocess.run([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0",
        "-i", concat_list,
        "-ar", str(SAMPLE_RATE), "-ac", "1",
        "-acodec", "pcm_s16le",
        FINAL_WAV
    ], capture_output=True, check=True)

    # Get final duration
    probe = subprocess.run([
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        FINAL_WAV
    ], capture_output=True, text=True)
    total_dur = probe.stdout.strip()

    # Write ground truth
    with open(GT_FILE, "w") as f:
        f.write("Ground Truth Speaker Labels\n")
        f.write("=" * 40 + "\n")
        for line in gt_lines:
            f.write(line + "\n")
            print(f"  {line}")

    print(f"\nWrote: {FINAL_WAV} ({total_dur}s)")
    print(f"Wrote: {GT_FILE}")

    # Clean up temp files
    for f in segment_files:
        if os.path.exists(f) and f != silence_file:
            os.remove(f)
    if os.path.exists(silence_file):
        os.remove(silence_file)
    if os.path.exists(concat_list):
        os.remove(concat_list)


if __name__ == "__main__":
    main()
