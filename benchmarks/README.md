# Benchmarks

This directory holds the **synthetic transcript** used by `scripts/benchmark_models.sh`
to measure summary quality and speed across local LLMs.

## Why a synthetic transcript

Public benchmarking with real meeting recordings is a privacy minefield —
even anonymized transcripts can leak company names, product details,
employee identities, or strategy discussions.

`synthetic-transcript.md` is a fictional Q2 all-hands meeting for a made-up
robotics company (Atlas Robotics). All names, projects, numbers, and decisions
are invented. The transcript imitates the structure and pacing of a real
60-minute corporate meeting (cross-functional updates, multiple speakers,
decisions, action items) so summary outputs are meaningful to compare.

## What gets committed

| File / Pattern | Tracked by git? |
|---|---|
| `synthetic-transcript.md` | ✅ yes — the fixture |
| `README.md` | ✅ yes |
| `<run-id>/` (benchmark output) | ❌ no (gitignored) |
| Any other file | ❌ no (gitignored) |

**Never** put a real meeting transcript in this directory. The
`.gitignore` is the last line of defense — primary defense is you.

## Running

```bash
# Baseline: Ollama's default 2K context (reproduces the bug)
NUM_CTX=2048 LABEL=ctx2k bash scripts/benchmark_models.sh benchmarks/synthetic-transcript.md

# Fix: full context window for each model
NUM_CTX=32768 LABEL=ctx32k bash scripts/benchmark_models.sh benchmarks/synthetic-transcript.md

# Gemma 4 advantage: 128K context
NUM_CTX=131072 LABEL=ctx128k bash scripts/benchmark_models.sh benchmarks/synthetic-transcript.md
```
