#!/bin/bash
# Benchmark Ollama models on a Scripta meeting transcript.
#
# Usage:
#   bash scripts/benchmark_models.sh [transcript.txt]
#
# Compares every model in $MODELS on the same transcript, using the same
# summary prompt Scripta sends in production. Captures wall-clock latency,
# tokens/sec (from Ollama's eval stats), output token count, and saves each
# model's response under benchmarks/<run-id>/.
#
# Output:
#   - Markdown table on stdout (paste into README / Dev.to article)
#   - benchmarks/<run-id>/results.json
#   - benchmarks/<run-id>/<model>.txt (raw summary text per model)

set -e

TRANSCRIPT="${1:-}"
MODELS="${MODELS:-qwen2.5:3b qwen2.5:1.5b llama3.2:3b llama3.2:1b gemma4:e2b gemma4:e4b}"
# num_ctx controls how much of the prompt Ollama actually feeds to the model.
# Default 2048 reproduces Ollama's stock behavior — set to 32768+ to use long context.
NUM_CTX="${NUM_CTX:-32768}"
LABEL="${LABEL:-ctx${NUM_CTX}}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$LABEL"
OUTDIR="benchmarks/$RUN_ID"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

if [ -z "$TRANSCRIPT" ]; then
    echo "Usage: $0 <transcript.txt>"
    echo "  Pass a real Scripta transcript (or any meeting transcript) as the first argument."
    exit 1
fi

if [ ! -f "$TRANSCRIPT" ]; then
    echo "Transcript file not found: $TRANSCRIPT"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq required. Install with: brew install jq"
    exit 1
fi

if ! curl -s "$OLLAMA_URL/api/tags" >/dev/null; then
    echo "Ollama not reachable at $OLLAMA_URL. Run: brew services start ollama"
    exit 1
fi

mkdir -p "$OUTDIR"
cp "$TRANSCRIPT" "$OUTDIR/transcript.txt"

TRANSCRIPT_BYTES=$(wc -c < "$TRANSCRIPT" | tr -d ' ')
TRANSCRIPT_WORDS=$(wc -w < "$TRANSCRIPT" | tr -d ' ')

# Prompt template kept in sync with SummaryService.swift:buildPrompt().
# Instructions are embedded in the prompt itself (no Ollama `system` field) —
# this matches Scripta's production behavior and avoids triggering reasoning
# models (e.g. Gemma 4) into thinking mode that consumes num_predict budget.
TRANSCRIPT_TEXT=$(cat "$TRANSCRIPT")
USER_PROMPT="You summarize meetings. Be concise. Output ONLY the summary, nothing else.

Summarize this meeting transcript.

TRANSCRIPT:
$TRANSCRIPT_TEXT
END TRANSCRIPT

Write a short summary (3-5 bullet points) and list any action items. Format:

SUMMARY:
- point 1
- point 2

ACTION ITEMS:
- task 1 (owner)
- task 2 (owner)

If no action items, write \"None identified.\""

RESULTS_JSON="$OUTDIR/results.json"
echo "[" > "$RESULTS_JSON"
FIRST=1

printf "\n%-18s  %10s  %10s  %14s  %12s  %10s\n" "model" "wall (s)" "tok/sec" "eval tokens" "ctx used" "fit?"
printf -- "----------------  ----------  ----------  --------------  ------------  ----------\n"

for MODEL in $MODELS; do
    # Skip if model is not installed.
    if ! curl -s "$OLLAMA_URL/api/tags" | jq -e ".models[].name | select(. == \"$MODEL\")" >/dev/null; then
        printf "%-18s  %10s  %10s  %14s  %12s  %10s\n" "$MODEL" "skip" "—" "—" "—" "not installed"
        continue
    fi

    BODY=$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$USER_PROMPT" \
        --argjson num_ctx "$NUM_CTX" \
        '{model: $model, prompt: $prompt, stream: false, options: {num_ctx: $num_ctx, num_predict: 1024, temperature: 0.4}}')

    START_NS=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000')
    RESPONSE=$(curl -s "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$BODY")
    END_NS=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000')
    WALL_MS=$((END_NS - START_NS))
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

    if [ -z "$SUMMARY" ] || [ "$SUMMARY" = "null" ]; then
        FIT="error"
    else
        FIT="ok"
    fi

    SAFE_NAME=$(echo "$MODEL" | tr ':/' '__')
    echo "$SUMMARY" > "$OUTDIR/$SAFE_NAME.txt"

    printf "%-18s  %10s  %10s  %14s  %12s  %10s\n" \
        "$MODEL" "$WALL_S" "$TOK_PER_SEC" "$EVAL_TOKENS" "$PROMPT_TOKENS" "$FIT"

    if [ $FIRST -eq 0 ]; then echo "," >> "$RESULTS_JSON"; fi
    FIRST=0
    jq -n \
        --arg model "$MODEL" \
        --argjson wall_ms "$WALL_MS" \
        --arg tok_per_sec "$TOK_PER_SEC" \
        --argjson prompt_tokens "$PROMPT_TOKENS" \
        --argjson eval_tokens "$EVAL_TOKENS" \
        --arg fit "$FIT" \
        '{model: $model, wall_ms: $wall_ms, tok_per_sec: $tok_per_sec, prompt_tokens: $prompt_tokens, eval_tokens: $eval_tokens, status: $fit}' \
        >> "$RESULTS_JSON"
done

echo "]" >> "$RESULTS_JSON"

cat <<INFO

Transcript: $TRANSCRIPT  (${TRANSCRIPT_BYTES} bytes, ~${TRANSCRIPT_WORDS} words)
num_ctx:    $NUM_CTX
Run ID:     $RUN_ID
Results saved to: $OUTDIR/
  - results.json
  - <model>.txt          (one file per model with its summary)
  - transcript.txt       (copy of the input)

To produce a markdown table for the README / blog:
  jq -r '.[] | "| \(.model) | \(.wall_ms / 1000)s | \(.tok_per_sec) | \(.eval_tokens) |"' $RESULTS_JSON

To run the "before" baseline (Ollama default 2K context):
  NUM_CTX=2048 LABEL=ctx2k bash scripts/benchmark_models.sh $TRANSCRIPT

To run the "after" full-context comparison:
  NUM_CTX=131072 LABEL=ctx128k bash scripts/benchmark_models.sh $TRANSCRIPT

INFO
