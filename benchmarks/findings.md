# Scripta + Gemma 4: benchmark findings

Run date: 2026-05-16
Hardware: Mac (see local benchmarks/*.json for full prompt_tokens, eval_duration_ns)
Transcript: synthetic-transcript.md, 19,357 chars / 3,135 words / ~5K tokens
Workflow: `scripts/benchmark_models.sh` invoked once per (model, num_ctx) pair.

## Quantitative results

| Model       | num_ctx | Wall  | tok/s | Output tokens |
|-------------|---------|-------|-------|---------------|
| qwen2.5:3b  | 2048    | 15.2s | 47.9  | 59            |
| gemma4:e2b  | 2048    | 106.9s¹| 41.7  | 267           |
| qwen2.5:3b  | 32768   | 25.7s | 39.3  | 222           |
| gemma4:e2b  | 32768   | 49.2s | 27.1  | 752           |

¹ Gemma 4 first-token latency includes cold model load (~80s on this hardware).
  Subsequent runs warm-cached are roughly half that wall clock.

## Qualitative observations

### qwen2.5:3b @ 2K — the "broken Scripta" baseline

Only summarizes the Q&A section at the end of the transcript. Lists three items
as the meeting's "key points": hybrid work policy, intern conversion path,
pricing impact on pipeline. These are minor Q&A topics, not the meeting's
content.

**Misses entirely**: Q2 ARR ($4.2M), headcount growth (47), Marcus Reyes joining
as VP Engineering, Project Lighthouse (the whole reason this meeting happened),
the 3x perception perf improvement, all five new engineer names, every tech debt
item, three new enterprise logos, Voice Control roadmap, Series B prep, the
Engineer of the Quarter award.

### gemma4:e2b @ 2K — the most interesting result

Like Qwen, only sees the tail of the transcript. But unlike Qwen, **Gemma 4
explicitly told the user the transcript looked incomplete**:

> "The provided transcript seems to be a mix of several unrelated topics, making
> it difficult to extract a single, coherent summary based on the provided text
> alone. ... If you are looking for a summary of the *actual* conversation
> content, please provide the relevant transcript."

This is the model recognizing that the context it received doesn't match a
plausible meeting structure. Reasoning behavior on a 4B-parameter model that
runs on a laptop.

It also duplicated one action item ("Prepare for the upcoming office move"
appears twice), suggesting Gemma 4 is filling output budget when content is thin.

### qwen2.5:3b @ 32K — Qwen with the bug fixed

Solid coverage of the meeting. Names the headline ARR, the new VP, the pricing
move. Lists 8 accurate action items.

Still misses some specifics that matter for a corporate summary: the three new
enterprise logos by name, Project Lighthouse specifically, Series B prep,
Engineer of the Quarter award.

### gemma4:e2b @ 32K — best result

Most comprehensive of all four. Mentions:

* $4.2M ARR exceeding plan
* Headcount expansion to 47
* **Three new logos by name** — Boeing, Amazon, FedEx
* **Project Lighthouse** with July 15 launch date
* Voice Control (Q3) and multi-robot coordination (Q4)
* **Series B prep** (strategic info from segment 5)
* Renewal rate 94%, NPS 67
* 9 accurate action items including the Lighthouse readiness review

The summary is roughly 3x longer than Qwen's and more useful as a meeting
artifact.

## What this means for Scripta

Before this work, Scripta had two compounding limits:

1. `SummaryService.swift:buildPrompt()` truncated the transcript to **3,000 chars**
   before sending to Ollama (a leftover guard from the early prototype).
2. The Ollama request had no `num_ctx` override, so Ollama applied its default
   of **2,048 tokens** regardless of the model's actual capability.

Either limit alone would have been bad; the combination meant **every Scripta
summary used at most ~750 tokens of context** (the prompt scaffolding plus tail
of the transcript). A 60-minute meeting compressed to roughly the last 5
minutes.

The fix is two lines:

```swift
"num_ctx": SummaryModelManager.contextWindow(for: modelName),
```

…plus dropping the 3,000-char truncation in favor of a context-aware tail
truncation that uses `model.contextTokens - 1200` (template + output reservation).

Adding Gemma 4 was the second piece. With 128K context, Gemma 4 lets Scripta
handle multi-hour meetings without any chunking. With Qwen 2.5 (32K context),
we cover most one-hour meetings; longer meetings need chunking or Gemma.

## Reproduce

```bash
NUM_CTX=2048  LABEL=ctx2k  bash scripts/benchmark_models.sh benchmarks/synthetic-transcript.md
NUM_CTX=32768 LABEL=ctx32k bash scripts/benchmark_models.sh benchmarks/synthetic-transcript.md
```
