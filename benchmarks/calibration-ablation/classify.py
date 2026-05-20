#!/usr/bin/env python3
"""Classify Gemma 4 ablation outputs against a pre-registered schema.

Reads outputs/<row>-run<N>.txt files produced by run.sh, applies a
keyword-based first-pass classification, and writes a Markdown table to
stdout plus a structured JSON file for follow-up analysis.

The classification schema is pre-registered BEFORE running the experiment
so that the verdict on each output is reproducible. The labels are:

    did_hedge: bool
        True if the model output contains any sentence flagging that the
        input is insufficient, truncated, mid-stream, or not a meeting.

    hedge_category: one of
        "length_complaint"      => "please provide more text/context",
                                   "the input is short"
        "content_complaint"     => "this doesn't look like a meeting",
                                   "mix of unrelated topics",
                                   "incoherent / not a transcript"
        "truncation_complaint"  => "appears cut off mid-sentence",
                                   "the sentence is incomplete",
                                   "text seems truncated"
        "mid_stream_complaint"  => "starts in the middle",
                                   "feels like an excerpt of a larger
                                   conversation"
        "none"                  => no hedge detected

    produced_summary: bool
        True if the model attempted a substantive summary regardless of
        any hedge (a hedge + a forced-attempt summary is a different
        behavior from a hedge + refusal).

The keyword matching is deliberately conservative. For ambiguous outputs
you are expected to override `auto_*` fields with a manual review and
commit the corrected JSON.
"""
from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUTPUTS_DIR = HERE / "outputs"

# --- Keyword patterns. Order matters: more specific patterns first. ----------

TRUNCATION_PATTERNS = [
    r"\bcut(\s|-)?off\b",
    r"\bcut\s+short\b",
    r"\btruncat(ed|ion)\b",
    r"\bincomplete\s+sentence\b",
    r"\bmid[- ]sentence\b",
    r"\bappears\s+to\s+end\b",
    r"\bends?\s+abruptly\b",
    r"\bunfinished\s+(sentence|thought)\b",
]

MID_STREAM_PATTERNS = [
    r"\bmid[- ]stream\b",
    r"\bmid[- ]conversation\b",
    r"\bexcerpt\b",
    r"\bsegment\s+of\s+a\s+larger\b",
    r"\bportion\s+of\s+a\s+larger\b",
    r"\bappears\s+to\s+(be|start|begin)\s+in\s+the\s+middle\b",
    r"\bonly\s+a\s+part\b",
]

CONTENT_PATTERNS = [
    r"\bnot\s+a\s+meeting\s+transcript\b",
    r"\bdoes\s+not\s+(appear|seem)\s+to\s+be\s+a\s+(meeting|transcript)\b",
    r"\bmix\s+of\s+(several\s+)?unrelated\s+topics\b",
    r"\bunrelated\s+topics\b",
    r"\bincoherent\b",
    r"\bnot\s+coherent\b",
    r"\bdoes\s+not\s+contain\s+a\s+meeting\b",
    r"\bappears\s+to\s+be\s+about\s+(an?\s+)?[A-Z][a-z]+",  # "appears to be about [topic]"
]

# Self-disclaimer / metacognitive hedge: the model produces a summary, then
# notes that the summary does not match the input. This is the pathological
# pattern observed at num_ctx=2048: templated hallucination + self-correction.
SELF_DISCLAIMER_PATTERNS = [
    r"\bdoes\s+not\s+contain\s+(the\s+)?information\s+listed\b",
    r"\bnot\s+explicitly\s+(present|stated)\s+in\s+the\s+(dialogue|transcript|text)\b",
    r"\binferred\s+based\s+on\b",
    r"\bimplied\s+by\s+the\s+(context|meeting|transcript)\b",
    r"\bnot\s+fully\s+detailed\s+in\s+the\s+provided\b",
    r"\bbased\s+\*?only\*?\s+on\s+the\s+(provided\s+)?(transcript|text)\b",
    r"\bbased\s+solely\s+on\s+the\s+(provided\s+)?(transcript|text)\b",
    r"\bthe\s+(provided\s+)?(snippet|transcript)\s+(does\s+not|doesn't)\s+(contain|include|specify)\b",
    r"\bnote\s*:\s*the\s+(provided\s+)?(transcript|text)\b",
]

LENGTH_PATTERNS = [
    r"\bplease\s+provide\s+(the\s+)?(more|additional|relevant|full|complete)\b",
    r"\bnot\s+enough\s+(context|information|text)\b",
    r"\binsufficient\s+(context|information)\b",
    r"\bbrief\s+(transcript|input|text)\b",
    r"\btoo\s+short\b",
    r"\bvery\s+short\s+(transcript|input)\b",
]

SUMMARY_INDICATOR_PATTERNS = [
    r"^\s*SUMMARY\s*:",  # the model followed the asked-for template
    r"^\s*-\s+",  # bullet point in output (some attempt at structured output)
    r"\bACTION\s+ITEMS?\s*:",
]

# Order matters: more specific patterns first. self_disclaimer is checked
# before content_complaint because the pathological-retry pattern at
# num_ctx=2048 produces "does not contain" wording that would otherwise
# be miscategorized.
CATEGORY_ORDER = [
    ("self_disclaimer", SELF_DISCLAIMER_PATTERNS),
    ("truncation_complaint", TRUNCATION_PATTERNS),
    ("mid_stream_complaint", MID_STREAM_PATTERNS),
    ("content_complaint", CONTENT_PATTERNS),
    ("length_complaint", LENGTH_PATTERNS),
]


@dataclass
class RunResult:
    row: str
    run: int
    output: str
    auto_did_hedge: bool = False
    auto_hedge_category: str = "none"
    auto_hedge_quote: str = ""
    auto_produced_summary: bool = False
    eval_tokens: int = 0
    wall_ms: int = 0
    # Manual overrides — fill in after reading the outputs.
    manual_did_hedge: bool | None = None
    manual_hedge_category: str | None = None
    manual_hedge_quote: str | None = None
    manual_produced_summary: bool | None = None
    notes: str = ""


def find_first_match(text: str, patterns: list[str]) -> str:
    for p in patterns:
        m = re.search(p, text, flags=re.IGNORECASE | re.MULTILINE)
        if m:
            sent = _enclosing_sentence(text, m.start())
            return sent.strip()
    return ""


def _enclosing_sentence(text: str, idx: int) -> str:
    start = max(text.rfind(".", 0, idx), text.rfind("\n", 0, idx))
    start = start + 1 if start >= 0 else 0
    end = text.find(".", idx)
    if end < 0:
        end = text.find("\n", idx)
    if end < 0:
        end = len(text)
    return text[start:end + 1]


def classify_output(text: str) -> tuple[bool, str, str, bool]:
    """Return (did_hedge, category, quote, produced_summary)."""
    hedge_quote = ""
    hedge_category = "none"
    for category, patterns in CATEGORY_ORDER:
        quote = find_first_match(text, patterns)
        if quote:
            hedge_category = category
            hedge_quote = quote
            break

    did_hedge = hedge_category != "none"

    produced_summary = False
    for p in SUMMARY_INDICATOR_PATTERNS:
        if re.search(p, text, flags=re.IGNORECASE | re.MULTILINE):
            produced_summary = True
            break

    return did_hedge, hedge_category, hedge_quote, produced_summary


def load_metadata(meta_path: Path) -> dict:
    if not meta_path.exists():
        return {}
    try:
        return json.loads(meta_path.read_text())
    except Exception:
        return {}


def main() -> int:
    if not OUTPUTS_DIR.exists():
        print(f"No outputs directory at {OUTPUTS_DIR}. Run run.sh first.")
        return 1

    results: list[RunResult] = []
    for txt_path in sorted(OUTPUTS_DIR.glob("*.txt")):
        stem = txt_path.stem  # e.g. row2-mid-session-paragraph-run1
        m = re.match(r"^(?P<row>.+)-run(?P<run>\d+)$", stem)
        if not m:
            continue
        row = m.group("row")
        run = int(m.group("run"))

        text = txt_path.read_text()
        meta = load_metadata(txt_path.with_suffix(".meta.json"))

        did_hedge, category, quote, produced = classify_output(text)
        results.append(
            RunResult(
                row=row,
                run=run,
                output=text.strip(),
                auto_did_hedge=did_hedge,
                auto_hedge_category=category,
                auto_hedge_quote=quote,
                auto_produced_summary=produced,
                eval_tokens=int(meta.get("eval_tokens", 0)),
                wall_ms=int(meta.get("wall_ms", 0)),
            )
        )

    if not results:
        print("No outputs found. Run run.sh first.")
        return 1

    classify_json = HERE / "classification.json"
    classify_json.write_text(
        json.dumps([asdict(r) for r in results], indent=2)
    )

    # --- Print Markdown summary table to stdout. ----------------------------
    print(f"# Calibration ablation — classification\n")
    print(f"Outputs: {len(results)} runs across "
          f"{len(set(r.row for r in results))} rows.\n")

    print("| row | run | hedged? | category | produced summary? | tokens | wall (s) |")
    print("|-----|-----|---------|----------|-------------------|--------|----------|")
    for r in results:
        print(
            f"| {r.row} | {r.run} "
            f"| {'yes' if r.auto_did_hedge else 'no'} "
            f"| {r.auto_hedge_category} "
            f"| {'yes' if r.auto_produced_summary else 'no'} "
            f"| {r.eval_tokens} "
            f"| {r.wall_ms / 1000:.1f} |"
        )

    print("\n## Hedge quotes (auto-detected)\n")
    for r in results:
        if r.auto_hedge_quote:
            print(f"**{r.row} run{r.run}** ({r.auto_hedge_category}):\n")
            print(f"> {r.auto_hedge_quote}\n")

    print("\n## Raw outputs\n")
    for r in results:
        print(f"### {r.row} run{r.run}\n")
        print("```")
        print(r.output)
        print("```")
        print()

    print(f"\nDetailed classification written to: {classify_json}")
    print("Manual review: open the JSON, set `manual_*` fields where you")
    print("disagree with the auto-classification, then re-run analysis.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
