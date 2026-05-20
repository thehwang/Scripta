# Calibration ablation: Gemma 4 E2B "refusal" behavior

A small ablation experiment to test whether Gemma 4 E2B's "I can't summarize
this, please provide the relevant transcript" behavior on truncated input
is **trained calibration** that distinguishes types of damage, a **class-level
"damaged input" heuristic**, or a **length artifact**.

This was designed in collaboration with Daniel Nwaneri (@dannwaneri on
Dev.to) as a follow-up to the discussion under
[his Gemma 4 Cloudflare MoE post](https://dev.to/dannwaneri).

## Hypotheses

Four working hypotheses, in order of increasing specificity:

1. **Length artifact** — model only hedges when token count is small,
   regardless of content. The original article's observation was a side
   effect of `num_ctx=2048` truncating any transcript to its tail.

2. **"Damaged input" as a class** — model has learned a single signal for
   "this input is broken" and the response is the same whether the damage
   is syntactic (cut mid-sentence) or semantic (mid-session excerpt).

3. **Differentiated calibration** — model distinguishes syntactic damage
   from semantic damage and signals them with different language.

4. **Tail-of-larger-document signal** *(added after first-pass null
   result on rows 2-4)* — the hedge tracks specifically "this looks like
   the end fragment of something longer, with the opening cut off" —
   which is exactly the shape Ollama's `num_ctx=2048` truncation produces
   on a 5K-token transcript, but NOT the shape of a deliberately-chosen
   mid-session paragraph (which has a natural sub-section opening like
   "Thanks Sarah, three buckets from product side").

Daniel's point: "mix of unrelated topics" (a content claim) is incompatible
with (1), so the floor for the model's actual behavior is (2) at minimum.
The first-pass result (rows 2-4 produced no hedge of any kind) refutes
(1), (2), and (3) for the inputs tested, which is what motivated adding
H4 and row 6.

## Inputs (length-matched within ~15%)

| Row | File | Words | Chars | Description |
|-----|------|-------|-------|-------------|
| 1 | `../synthetic-transcript.md` | 3,135 | 19,357 | Full session, ground truth |
| 2 | `inputs/row2-mid-session-paragraph.txt` | 273 | 1,732 | James's customer + pricing section, untouched. Semantically mid-stream, syntactically whole. High discontinuity density (topic jumps, dangling references). **Has a natural sub-section opening.** |
| 3 | `inputs/row3-mid-session-cut.txt` | 255 | 1,615 | Same as row 2, cut mid-word at "rare earth ma-". Syntactically broken AND semantically mid-stream. |
| 4 | `inputs/row4-clean-prose.txt` | 243 | 1,610 | Wikipedia-style passage on the Antikythera mechanism. Self-contained, syntactically whole, semantically coherent. Low discontinuity. |
| 5 | `inputs/row5-clean-prose-cut.txt` | 222 | 1,448 | Row 4 cut mid-word at "various di-". Syntactically broken, semantically coherent up to the cut. |
| 6 | `inputs/row6-tail-of-session.txt` | 264 | 1,611 | Tail of the synthetic transcript starting at Robert's question. Semantically mid-stream, syntactically whole, **no sub-section opening** — mid-meeting references appear without setup ("the fifteen percent pricing increase"). Simulates what Ollama's `num_ctx=2048` truncation produces on a 5K-token transcript. |

Row 1 is the existing benchmark target — not re-run here, only referenced
for context. The harness operates on rows 2–4 by default, with row 5
conditional on whether 2-vs-3 produces a clear signal.

## Diagnostic matrix

| Outcome (rows 2/3 only) | Interpretation |
|-------------------------|----------------|
| Row 2 hedges, row 3 hedges, **same category/wording** | Hypothesis 2: "damaged input as a class" |
| Row 2 hedges, row 3 hedges, **different categories** (e.g. content vs truncation) | Hypothesis 3: differentiated calibration |
| Row 2 doesn't hedge, row 3 hedges | Truncation-specific signal, not transcript-distribution signal |
| Row 2 hedges, row 3 doesn't hedge | Unexpected — would invert intuition; investigate |
| Neither hedges | H1, H2, H3 refuted for these inputs; H4 still in play (test with row 6) |

Row 4 then disambiguates:

| Row 4 outcome | Interpretation when combined with 2/3 |
|---------------|----------------------------------------|
| Row 4 doesn't hedge | Hedge tracks transcript-distribution features, not length |
| Row 4 hedges with content_complaint ("not a meeting") | Model checks input-against-prompt alignment, hedging is prompt-driven not input-driven |
| Row 4 hedges identically to row 2 | Hedge is purely length-driven (refutes Daniel's point) |

Row 6 tests H4 directly:

| Row 6 outcome | Interpretation |
|---------------|----------------|
| Row 6 hedges, rows 2/3/4 don't | **H4 confirmed**. The hedge tracks "tail-without-opening" specifically. The original article's hedge was triggered by Ollama's `num_ctx=2048` chopping the transcript's opening off, not by short input or damaged input in general. |
| Row 6 doesn't hedge | H4 refuted along with H1/H2/H3. The hedge requires something specific to `num_ctx=2048` itself (e.g., context-budget pressure) that isn't reproducible with `num_ctx=32768` on the same content. Worth re-running row 6 at `NUM_CTX=2048`. |
| Row 6 hedges with `truncation_complaint` wording | Model is detecting structural truncation, not content shape; complements the row 3 result. |
| Row 6 hedges with `mid_stream_complaint` wording | Model is detecting "this is an excerpt" specifically — cleanest possible signal for H4. |

Row 5 (if run) isolates whether truncation signature alone triggers the
hedge regardless of content distribution.

## Running

```bash
# Default: rows 2, 3, 4, 6, three runs each (the canonical experiment)
bash run.sh

# Selectively run a subset (comma separated, "rowN" aliases supported)
bash run.sh --rows row6
bash run.sh --rows row2,row3

# After 2-vs-3 ambiguous outcome: add row 5
bash run.sh --with-row5

# Increase replication
bash run.sh --runs 5

# Truncate results.jsonl before running (default: append)
bash run.sh --reset

# Try a different model
MODEL=gemma4:e4b bash run.sh    # if you have 32GB+ RAM and want to compare
```

Default parameters (overridable via environment):
- `MODEL=gemma4:e2b`
- `NUM_CTX=32768` (well above the input length, so context-window is not the constraint)
- `TEMPERATURE=0.0` (minimize sampling noise; deviates from Scripta's production 0.4)
- `NUM_RUNS=3` (low but enough to spot consistency)

Expected wall time on a 16 GB M-series Mac:
- Cold start: ~80s (first inference loads model weights)
- Per-run after that: ~15–30s
- 4 rows × 3 runs = 12 inferences = **~6–10 minutes total**
- With row 5 = ~8–12 minutes

If you've already run rows 2-4 in a previous session, just add row 6:

```bash
bash run.sh --rows row6        # ~90 seconds, appends to existing results
python3 classify.py > classification-report.md
```

## Output structure

```
outputs/
├── row2-mid-session-paragraph-run1.txt        (raw model response)
├── row2-mid-session-paragraph-run1.meta.json  (tokens, wall_ms, temperature)
├── row2-mid-session-paragraph-run2.txt
├── ... (one set per row × run)
results.jsonl                                   (one line per run, aggregated)
classification.json                             (after running classify.py)
```

## Classifying outputs

```bash
python3 classify.py > classification-report.md
```

This produces a Markdown report with:
- A table of (row, run, did_hedge, hedge_category, produced_summary, tokens, wall)
- The auto-extracted hedge sentence for each run (for verbatim comparison)
- All raw outputs inline (for manual override)

The classification uses keyword pattern matching against a pre-registered
schema (see `classify.py` docstring). Categories are:
- `truncation_complaint` — flags mid-sentence cut
- `mid_stream_complaint` — flags excerpt-of-larger
- `content_complaint` — flags not-a-meeting / unrelated-topics
- `length_complaint` — flags brief / insufficient
- `none` — no hedge

For ambiguous outputs, edit `classification.json` and set the `manual_*`
fields. The schema is pre-registered to avoid post-hoc verdict drift.

## What to do with results

After running and classifying:

1. **Read `classification-report.md`** — confirm or override the
   auto-classification for any ambiguous outputs.
2. **Check 2-vs-3 outcome** against the diagnostic matrix above.
3. **If ambiguous**, run with `--with-row5`.
4. **Post the table** as a follow-up Dev.to comment under
   [the original thread](https://dev.to/dannwaneri) — Daniel and vericum
   are explicitly waiting for these deltas.
5. **If the signal is strong enough** to make a clean technical claim,
   consider writing a short follow-up Dev.to post citing both Daniel's
   experimental design contribution and vericum's planned RTX 4060
   replication.

## Limitations

- **3 runs per row is low** — temperature=0.0 reduces variance but GPU
  non-determinism still produces token-level drift. For publication-quality
  claims, repeat with `--runs 10`.
- **Length matched within ~15%, not exactly** — row 4 (1610 chars) is
  within 7% of row 2 (1732 chars), but row 5 (1448 chars) is 17% shorter
  than row 2. Length effects below ~20% are unlikely to dominate, but
  document this if reporting.
- **Single model size tested** — results may not generalize to E4B or 31B.
  vericum is independently testing on a different hardware envelope
  (RTX 4060 8GB) which is the planned cross-validation.
- **Prompt is Scripta's production prompt** — it explicitly asks for
  "meeting transcript" summary. Row 4 (clean prose, not a meeting) is
  therefore in a mismatched-prompt condition by design. If you want to
  isolate input-content effects from prompt-misalignment effects, you
  would need a second pass with a generic "summarize this text" prompt;
  that is out of scope for this round.
