#!/usr/bin/env bash
# Gemma 4 multimodal demo — cross-reference a meeting slide vs the transcript.
#
# Feeds Gemma 4 both the synthetic Atlas Robotics transcript AND a presentation
# slide that was "shown" during that meeting. The slide contains two intentional
# inconsistencies vs the transcript:
#   - Pricing increase:           slide says 20%,       transcript says 15%
#   - Project Lighthouse launch:  slide says July 22,   transcript says July 15
#
# A useful multimodal meeting assistant should catch both. In practice, at E2B
# size, Gemma 4's vision tower struggles — see the blog post for the full
# write-up of both failure modes.
#
# Usage:
#   bash benchmarks/multimodal/run.sh                      # loose prompt (default)
#   STRICT_PROMPT=1 bash benchmarks/multimodal/run.sh      # strict grounded prompt
#   MODEL=gemma4:e4b bash benchmarks/multimodal/run.sh     # try a bigger model
#   OLLAMA_URL=http://localhost:11434 bash benchmarks/multimodal/run.sh

set -euo pipefail

cd "$(dirname "$0")"

MODEL="${MODEL:-gemma4:e2b}"
IMG_PATH="q2-allhands-slide.png"
TRANSCRIPT="../synthetic-transcript.md"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
STRICT_PROMPT="${STRICT_PROMPT:-0}"

# ── Preflight checks ────────────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
    echo "jq required. Install with: brew install jq" >&2
    exit 1
fi

if ! curl -fs "$OLLAMA_URL/api/tags" >/dev/null; then
    echo "Ollama not reachable at $OLLAMA_URL. Run: brew services start ollama" >&2
    exit 1
fi

if [ ! -f "$IMG_PATH" ]; then
    echo "Slide image not found: $IMG_PATH" >&2
    exit 1
fi

if [ ! -f "$TRANSCRIPT" ]; then
    echo "Transcript not found: $TRANSCRIPT" >&2
    exit 1
fi

# ── Build payload ───────────────────────────────────────────────────────────
# Image + transcript are too large to pass as CLI arguments (macOS ARG_MAX
# is around 1 MB; a 1.3 MB image base64-encodes to ~1.7 MB). Route everything
# through temp files so neither jq nor curl ever sees the big strings on argv.

TMPDIR=$(mktemp -d -t scripta-mm.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

base64 < "$IMG_PATH" | tr -d '\n' > "$TMPDIR/img.b64"

if [ "$STRICT_PROMPT" = "1" ]; then
    {
        cat <<'PROMPT_HEADER'
You are auditing a Q2 all-hands meeting at Atlas Robotics. You have:
- An IMAGE of a slide shown during the meeting (attached)
- The full TRANSCRIPT of what was said (below)

Follow this procedure exactly:

STEP 1 — Read the slide.
List every specific value, date, or named item that is visually rendered
on the slide. Do not infer, do not extrapolate, do not add items that
are not literally shown on the slide. If a value is partially unreadable,
write "(unclear)" instead of guessing.

STEP 2 — Match against the transcript.
For each item from Step 1, search the transcript for the corresponding
information and quote it verbatim. If the transcript does not mention
that item, write "(not found)".

STEP 3 — Verdict.
Classify each item as one of:
- MATCH        — slide value and transcript agree
- MISMATCH     — slide value and transcript disagree
- NOT MENTIONED — slide item has no corresponding statement in transcript

Output one entry per item, in this exact format:

  Item:        <name as shown on slide>
  Slide:       <exact value as rendered on the slide>
  Transcript:  <verbatim quote, or "(not found)">
  Verdict:     MATCH | MISMATCH | NOT MENTIONED

After all items, end with a single line:

  Total mismatches: N

Hard rules:
- Never invent slide values. If you cannot clearly read a value, omit
  that item or mark it "(unclear)".
- Never invent transcript quotes. The Transcript field must be a
  verbatim substring of the transcript below, or "(not found)".
- Quote numbers in the form they appear (e.g. "$4.2M", "47", "94%").

Transcript:
PROMPT_HEADER
        cat "$TRANSCRIPT"
    } > "$TMPDIR/prompt.txt"
else
    {
        cat <<'PROMPT_HEADER'
You are reviewing a Q2 all-hands meeting at Atlas Robotics.

Below is the transcript of the meeting. Attached as an image is a slide
that was shown to the room during the same meeting. Cross-reference them
and identify any inconsistencies between what was said and what the
slide displays.

For each inconsistency, output a row in this format:

  Metric:        <name of metric>
  Slide:         <what the slide shows>
  Transcript:    <what the transcript says>
  Likely truth:  <which one and a one-sentence reason>

If everything is consistent, say "No inconsistencies found."

Transcript:
PROMPT_HEADER
        cat "$TRANSCRIPT"
    } > "$TMPDIR/prompt.txt"
fi

jq -n \
    --arg model "$MODEL" \
    --rawfile prompt "$TMPDIR/prompt.txt" \
    --rawfile img "$TMPDIR/img.b64" \
    '{
        model: $model,
        prompt: $prompt,
        images: [$img],
        stream: false,
        options: {
            temperature: 0.2,
            num_ctx: 32768
        }
    }' > "$TMPDIR/payload.json"

# ── Call Ollama ─────────────────────────────────────────────────────────────

PROMPT_MODE="loose"
[ "$STRICT_PROMPT" = "1" ] && PROMPT_MODE="strict"
echo "Calling $MODEL with slide + transcript ($(wc -c < "$IMG_PATH" | tr -d ' ') byte image, $(wc -w < "$TRANSCRIPT" | tr -d ' ') word transcript, prompt=$PROMPT_MODE)..." >&2
echo "" >&2

START=$(date +%s)
RESPONSE=$(curl -s "$OLLAMA_URL/api/generate" -d @"$TMPDIR/payload.json")
ELAPSED=$(( $(date +%s) - START ))

ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')
if [ -n "$ERROR" ]; then
    echo "Ollama returned an error:" >&2
    echo "  $ERROR" >&2
    echo "" >&2
    echo "If the error mentions images/vision, your local Gemma 4 tag may be" >&2
    echo "text-only. Check 'ollama list' and try a vision-enabled variant." >&2
    exit 1
fi

echo "$RESPONSE" | jq -r '.response'
echo "" >&2
echo "── done in ${ELAPSED}s ──" >&2
