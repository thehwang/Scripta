#!/bin/bash
# Calibration ablation experiment for Gemma 4 E2B.
#
# Hypothesis space (working theories):
#
#   H1 — Length artifact: model hedges on short inputs regardless of content.
#   H2 — "Damaged input as a class": any broken input triggers the same hedge.
#   H3 — Differentiated calibration: model distinguishes syntactic vs semantic
#        damage with different hedge wording.
#   H4 — Tail-of-larger-document signal: the hedge specifically tracks
#        "this looks like the end fragment of something longer, with the
#        opening missing" — which is exactly what Ollama's num_ctx=2048
#        truncation produces on a 5K-token transcript.
#
# Rows tested:
#
#   row1 = full session (existing synthetic-transcript.md, reference only)
#   row2 = mid-session paragraph, untouched (natural sub-section opening
#          preserved). Tests H1, H2.
#   row3 = same as row2, cut mid-sentence. Tests H2, H3 (with row2).
#   row4 = clean self-contained prose (Antikythera). Tests H1 isolated from
#          transcript-distribution features.
#   row5 = clean prose cut mid-sentence (conditional, isolates truncation
#          signature from content distribution).
#   row6 = tail of synthetic transcript without the section opening (Q&A
#          section starting mid-conversation). Tests H4 directly.
#
# Usage:
#   bash run.sh                        # runs the default set (rows 2,3,4,6)
#   bash run.sh --rows row6            # run only row 6 (appends to outputs)
#   bash run.sh --rows row2,row3       # run a subset (comma separated)
#   bash run.sh --with-row5            # include the conditional row 5
#   bash run.sh --runs 5               # use 5 replications per row
#   bash run.sh --reset                # truncate results.jsonl before running
#   MODEL=gemma4:e4b bash run.sh       # try a larger Gemma 4 variant
#
# Output:
#   outputs/<row>-run<N>.txt         raw model response (overwritten per row)
#   outputs/<row>-run<N>.meta.json   per-run metadata
#   results.jsonl                    aggregated log (appended by default)

set -e

MODEL="${MODEL:-gemma4:e2b}"
NUM_CTX="${NUM_CTX:-32768}"
NUM_RUNS="${NUM_RUNS:-3}"
TEMPERATURE="${TEMPERATURE:-0.0}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# CLI shortcut: "rowN" → full file stem. bash 3.2 compatible (no assoc arrays).
resolve_row_alias() {
    case "$1" in
        row1) echo "row1-full-session" ;;
        row2) echo "row2-mid-session-paragraph" ;;
        row3) echo "row3-mid-session-cut" ;;
        row4) echo "row4-clean-prose" ;;
        row5) echo "row5-clean-prose-cut" ;;
        row6) echo "row6-tail-of-session" ;;
        *)    echo "$1" ;;
    esac
}

ROWS_DEFAULT=(row2-mid-session-paragraph row3-mid-session-cut row4-clean-prose row6-tail-of-session)
ROWS=()
WITH_ROW5=0
RESET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --with-row5) WITH_ROW5=1; shift ;;
        --rows) IFS=',' read -ra ROW_ARGS <<< "$2"; shift 2
            for r in "${ROW_ARGS[@]}"; do
                ROWS+=("$(resolve_row_alias "$r")")
            done ;;
        --rows=*) IFS=',' read -ra ROW_ARGS <<< "${1#--rows=}"; shift
            for r in "${ROW_ARGS[@]}"; do
                ROWS+=("$(resolve_row_alias "$r")")
            done ;;
        --runs) NUM_RUNS="$2"; shift 2 ;;
        --runs=*) NUM_RUNS="${1#--runs=}"; shift ;;
        --reset) RESET=1; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [ ${#ROWS[@]} -eq 0 ]; then
    ROWS=("${ROWS_DEFAULT[@]}")
fi

if [ "$WITH_ROW5" -eq 1 ]; then
    ROWS+=(row5-clean-prose-cut)
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq required. Install with: brew install jq"
    exit 1
fi

if ! curl -s "$OLLAMA_URL/api/tags" >/dev/null; then
    echo "Ollama not reachable at $OLLAMA_URL. Run: brew services start ollama"
    exit 1
fi

if ! curl -s "$OLLAMA_URL/api/tags" | jq -e ".models[].name | select(. == \"$MODEL\")" >/dev/null; then
    echo "Model '$MODEL' not installed. Run: ollama pull $MODEL"
    exit 1
fi

mkdir -p outputs
if [ "$RESET" -eq 1 ]; then
    : > results.jsonl
elif [ ! -f results.jsonl ]; then
    : > results.jsonl
fi

build_prompt() {
    local input_text="$1"
    cat <<PROMPT
You summarize meetings. Be concise. Output ONLY the summary, nothing else.

Summarize this meeting transcript.

TRANSCRIPT:
$input_text
END TRANSCRIPT

Write a short summary (3-5 bullet points) and list any action items. Format:

SUMMARY:
- point 1
- point 2

ACTION ITEMS:
- task 1 (owner)
- task 2 (owner)

If no action items, write "None identified."
PROMPT
}

echo "Model: $MODEL"
echo "num_ctx: $NUM_CTX"
echo "Temperature: $TEMPERATURE"
echo "Runs per row: $NUM_RUNS"
echo "Rows: ${ROWS[*]}"
if [ "$RESET" -eq 1 ]; then echo "results.jsonl: reset"; else echo "results.jsonl: appending"; fi
echo

printf "%-32s  %-5s  %10s  %10s  %12s\n" "row" "run" "wall (s)" "tok/s" "eval tokens"
printf -- "--------------------------------  -----  ----------  ----------  ------------\n"

for ROW in "${ROWS[@]}"; do
    INPUT_FILE="inputs/$ROW.txt"

    if [ ! -f "$INPUT_FILE" ]; then
        echo "Missing input: $INPUT_FILE"
        exit 1
    fi

    INPUT_TEXT=$(cat "$INPUT_FILE")
    USER_PROMPT=$(build_prompt "$INPUT_TEXT")
    INPUT_CHARS=$(wc -c < "$INPUT_FILE" | tr -d ' ')

    for RUN in $(seq 1 "$NUM_RUNS"); do
        BODY=$(jq -n \
            --arg model "$MODEL" \
            --arg prompt "$USER_PROMPT" \
            --argjson num_ctx "$NUM_CTX" \
            --argjson temperature "$TEMPERATURE" \
            '{model: $model, prompt: $prompt, stream: false, options: {num_ctx: $num_ctx, num_predict: 1024, temperature: $temperature}}')

        START_MS=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000')
        RESPONSE=$(curl -s "$OLLAMA_URL/api/generate" \
            -H "Content-Type: application/json" \
            -d "$BODY")
        END_MS=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000')
        WALL_MS=$((END_MS - START_MS))
        WALL_S=$(echo "scale=2; $WALL_MS / 1000" | bc)

        SUMMARY=$(echo "$RESPONSE" | jq -r '.response // ""')
        PROMPT_TOKENS=$(echo "$RESPONSE" | jq -r '.prompt_eval_count // 0')
        EVAL_TOKENS=$(echo "$RESPONSE" | jq -r '.eval_count // 0')
        EVAL_DURATION_NS=$(echo "$RESPONSE" | jq -r '.eval_duration // 0')

        if [ "$EVAL_DURATION_NS" -gt 0 ] && [ "$EVAL_TOKENS" -gt 0 ]; then
            TOK_PER_SEC=$(echo "scale=1; $EVAL_TOKENS * 1000000000 / $EVAL_DURATION_NS" | bc)
        else
            TOK_PER_SEC="—"
        fi

        OUT_TXT="outputs/${ROW}-run${RUN}.txt"
        OUT_META="outputs/${ROW}-run${RUN}.meta.json"
        echo "$SUMMARY" > "$OUT_TXT"
        jq -n \
            --arg row "$ROW" \
            --argjson run "$RUN" \
            --arg model "$MODEL" \
            --argjson num_ctx "$NUM_CTX" \
            --argjson temperature "$TEMPERATURE" \
            --argjson input_chars "$INPUT_CHARS" \
            --argjson wall_ms "$WALL_MS" \
            --arg tok_per_sec "$TOK_PER_SEC" \
            --argjson prompt_tokens "$PROMPT_TOKENS" \
            --argjson eval_tokens "$EVAL_TOKENS" \
            '{row: $row, run: $run, model: $model, num_ctx: $num_ctx, temperature: $temperature, input_chars: $input_chars, wall_ms: $wall_ms, tok_per_sec: $tok_per_sec, prompt_tokens: $prompt_tokens, eval_tokens: $eval_tokens}' \
            > "$OUT_META"

        # Append as true JSON Lines: compact (one record per line) so the
        # file is parseable by streaming readers and `jq -c` consumers.
        jq -c . "$OUT_META" >> results.jsonl

        printf "%-32s  %-5s  %10s  %10s  %12s\n" "$ROW" "$RUN" "$WALL_S" "$TOK_PER_SEC" "$EVAL_TOKENS"
    done
done

echo
echo "Done. Raw outputs in outputs/, metadata in results.jsonl."
echo
echo "Next step: re-classify with"
echo "  python3 classify.py > classification-report.md"
