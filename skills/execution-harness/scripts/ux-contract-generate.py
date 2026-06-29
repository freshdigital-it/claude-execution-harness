#!/usr/bin/env python3
"""
ux-contract-generate.py — Generate UX contract YAML drafts from high-fidelity prototype HTML.

Usage:
  python3 ux-contract-generate.py <prototype.html> [--output <dir>] [--tokens-only]
  python3 ux-contract-generate.py design/App.html --output ux-contracts/
  python3 ux-contract-generate.py design/App.html --tokens-only > design-tokens.json

What it does:
  1. Parses prototype HTML to find distinct screens/sections
  2. Extracts: CTAs, form fields, table columns, status elements, CSS variables
  3. Generates YAML contract draft per screen (status: draft — human must approve)
  4. Generates design-tokens.json from CSS custom properties

Output: ux-contracts/<screen-id>.yaml (status: draft, needs human review)
Human then:
  - Fills in behavioral assertions (journeys, edge cases)
  - Sets status: approved
  - Only approved contracts are used by the harness loop
"""

import sys
import os
import json
import re
import argparse
from html.parser import HTMLParser
from pathlib import Path


class ScreenExtractor(HTMLParser):
    """Extract screen sections and UI elements from prototype HTML."""

    def __init__(self):
        super().__init__()
        self.screens = {}          # id -> {title, elements, css_vars}
        self.css_vars = {}         # --var-name -> value
        self._current_screen = None
        self._stack = []
        self._depth = 0
        self._in_style = False
        self._style_content = ""
        self._in_nav = False

    # --- HTML parsing ---

    def handle_starttag(self, tag, attrs):
        attr_dict = dict(attrs)
        self._stack.append((tag, attr_dict))
        self._depth += 1

        # Detect style block
        if tag == "style":
            self._in_style = True

        # Detect nav (skip nav items as screens)
        if tag == "nav" or attr_dict.get("role") == "navigation":
            self._in_nav = True

        # Screen detection: look for id + class patterns
        elem_id = attr_dict.get("id", "")
        classes = attr_dict.get("class", "")

        is_screen = (
            any(kw in elem_id for kw in ["page", "screen", "view", "panel", "section", "tab"])
            or any(kw in classes for kw in ["page", "screen", "view", "main-content"])
            or (tag in ("section", "main", "article") and elem_id)
        )

        if is_screen and elem_id and not self._in_nav:
            if elem_id not in self.screens:
                self.screens[elem_id] = {
                    "id": elem_id,
                    "title": self._title_from_id(elem_id),
                    "buttons": [],
                    "forms": [],
                    "tables": [],
                    "status_elements": [],
                    "empty_states": [],
                    "loading_states": [],
                    "error_states": [],
                }
            self._current_screen = elem_id

        # Extract UI elements into current screen
        if self._current_screen:
            screen = self.screens[self._current_screen]
            # Buttons / CTAs
            if tag == "button" or (tag == "a" and attr_dict.get("class")):
                text_hint = attr_dict.get("aria-label", attr_dict.get("title", ""))
                btn_type = "primary" if "primary" in classes or "btn-primary" in classes else "secondary"
                screen["buttons"].append({"type": btn_type, "label_hint": text_hint, "classes": classes[:60]})
            # Form inputs
            if tag == "input":
                screen["forms"].append({
                    "type": attr_dict.get("type", "text"),
                    "name": attr_dict.get("name", attr_dict.get("id", "")),
                    "required": "required" in attr_dict,
                })
            # Table headers
            if tag == "th":
                if not screen["tables"] or screen["tables"][-1].get("_closed"):
                    screen["tables"].append({"columns": [], "_closed": False})
                if screen["tables"]:
                    screen["tables"][-1]["columns"].append("")
            # Empty/loading/error state divs
            if tag in ("div", "section", "aside"):
                if any(kw in classes for kw in ["empty", "empty-state", "no-data", "blank"]):
                    screen["empty_states"].append({"classes": classes[:60]})
                if any(kw in classes for kw in ["loading", "skeleton", "spinner", "shimmer"]):
                    screen["loading_states"].append({"classes": classes[:60]})
                if any(kw in classes for kw in ["error", "alert", "danger", "toast-error"]):
                    screen["error_states"].append({"classes": classes[:60]})

    def handle_endtag(self, tag):
        if self._stack:
            self._stack.pop()
        self._depth -= 1
        if tag == "style":
            self._in_style = False
            self._parse_css_vars(self._style_content)
            self._style_content = ""
        if tag in ("nav",):
            self._in_nav = False

    def handle_data(self, data):
        if self._in_style:
            self._style_content += data
        # Capture button text for labeling
        if self._current_screen and self._stack:
            top_tag = self._stack[-1][0] if self._stack else ""
            if top_tag == "button" and data.strip():
                screen = self.screens[self._current_screen]
                if screen["buttons"]:
                    if not screen["buttons"][-1].get("label"):
                        screen["buttons"][-1]["label"] = data.strip()[:50]
            if top_tag == "th" and data.strip():
                screen = self.screens[self._current_screen]
                if screen["tables"] and screen["tables"][-1]["columns"]:
                    screen["tables"][-1]["columns"][-1] = data.strip()[:30]

    def _parse_css_vars(self, css_text):
        """Extract CSS custom properties (--var: value)."""
        matches = re.findall(r'--([\w-]+)\s*:\s*([^;}\n]+)', css_text)
        for name, value in matches:
            self.css_vars[f"--{name}"] = value.strip()

    @staticmethod
    def _title_from_id(elem_id):
        return elem_id.replace("-", " ").replace("_", " ").title()


def generate_tokens_json(css_vars: dict) -> dict:
    """Bucket CSS vars into semantic groups."""
    tokens = {"colors": {}, "spacing": {}, "typography": {}, "radius": {}, "shadow": {}, "other": {}}
    for var, val in css_vars.items():
        name = var.lstrip("-")
        if any(k in name for k in ["color", "bg", "background", "surface", "text", "border"]):
            tokens["colors"][var] = val
        elif any(k in name for k in ["space", "gap", "padding", "margin", "size"]):
            tokens["spacing"][var] = val
        elif any(k in name for k in ["font", "text-size", "line-height", "weight"]):
            tokens["typography"][var] = val
        elif any(k in name for k in ["radius", "rounded", "corner"]):
            tokens["radius"][var] = val
        elif "shadow" in name:
            tokens["shadow"][var] = val
        else:
            tokens["other"][var] = val
    # Remove empty groups
    return {k: v for k, v in tokens.items() if v}


def screen_to_yaml(screen: dict, prototype_file: str) -> str:
    """Convert extracted screen data to YAML contract draft."""
    sid = screen["id"]
    title = screen["title"]

    buttons_yaml = ""
    for btn in screen["buttons"][:6]:  # cap at 6
        label = btn.get("label") or btn.get("label_hint") or "unlabeled"
        buttons_yaml += f"    # - {btn['type']}: \"{label}\"\n"

    forms_yaml = ""
    for f in screen["forms"][:8]:
        req = " (required)" if f["required"] else ""
        forms_yaml += f"    # - {f['type']}: {f['name']}{req}\n"

    cols = []
    for tbl in screen["tables"]:
        cols.extend([c for c in tbl["columns"] if c])
    cols_yaml = ", ".join(f'"{c}"' for c in cols[:8]) if cols else '"col1", "col2"'

    has_empty = bool(screen["empty_states"])
    has_loading = bool(screen["loading_states"])
    has_error = bool(screen["error_states"])

    return f"""# UX Contract — {title}
# AUTO-GENERATED DRAFT from {prototype_file}
# Review, fill in TODOs, then set status: approved
# Only approved contracts are used by the harness loop.

status: draft   # change to: approved  (after human review)

screen: {sid}
prototype_source: {prototype_file}
prototype_section: "#{sid}"   # update if section uses different id

# --- STATES ---
# Extracted from HTML structure. Verify and fill in details.

states:
  loading:
    detected: {str(has_loading).lower()}
    required:
      - skeleton rows or spinner visible   # TODO: describe what loading looks like
      - action buttons disabled
      # - header still visible

  empty:
    detected: {str(has_empty).lower()}
    required:
      - illustration or icon              # TODO: describe empty state visuals
      - descriptive text (not just "No data")
      - CTA button: "TODO: what action?"  # FILL IN

  error:
    detected: {str(has_error).lower()}
    required:
      - inline error banner (not full page redirect)
      - retry or recovery action
      - message never shows raw error/undefined/stack trace

  data:
    columns: [{cols_yaml}]
    required:
      - row hover state visible
      # - bulk action bar on row select    # TODO: uncomment if applicable
      # - pagination or infinite scroll    # TODO: choose one

# --- DETECTED UI ELEMENTS ---
# Auto-detected buttons / forms. Verify labels and add behavioral assertions.

detected_buttons:
{buttons_yaml or '    # none detected — add manually\n'}
detected_forms:
{forms_yaml or '    # none detected — add manually\n'}

# --- JOURNEYS ---
# TODO: Define at least 2 journeys (create flow + one other).
# These become Playwright test cases. Be specific about selectors.

journeys:
  - id: primary_action   # TODO: rename
    steps:
      - trigger: "TODO: click [what button/link?]"
      - expect: "TODO: what should appear?"
      - action: "TODO: what does user do next?"
      - expect: "TODO: what is the success state?"

  - id: error_path
    steps:
      - trigger: "TODO: trigger that causes an error"
      - expect: "inline error banner visible, not redirect"
      - expect: "error message is human-readable"

# --- PRODUCTION GRADE RUBRIC ---
# All must be true for task to be considered done.

production_grade_rubric:
  loading_state: true          # skeleton/spinner present, not blank freeze
  empty_state_cta: true        # empty state has actionable CTA
  error_never_raw: true        # no raw errors, undefined, or stack traces shown
  hover_focus_states: true     # all interactive elements have hover+focus
  keyboard_navigable: true     # tab through all primary actions
  error_inline: true           # errors are inline, never full-page redirect
  transitions_smooth: true     # loading feedback on all async operations

pass_threshold: 12             # out of 14 rubric points (see fe-execution.md)
"""


def main():
    parser = argparse.ArgumentParser(description="Generate UX contract YAML from prototype HTML")
    parser.add_argument("prototype", help="Path to prototype HTML file")
    parser.add_argument("--output", "-o", default="ux-contracts", help="Output directory for YAML files")
    parser.add_argument("--tokens-only", action="store_true", help="Only output design-tokens.json to stdout")
    args = parser.parse_args()

    proto_path = Path(args.prototype)
    if not proto_path.exists():
        print(f"Error: {proto_path} not found", file=sys.stderr)
        sys.exit(1)

    html_content = proto_path.read_text(encoding="utf-8", errors="replace")

    extractor = ScreenExtractor()
    extractor.feed(html_content)

    if args.tokens_only:
        tokens = generate_tokens_json(extractor.css_vars)
        print(json.dumps(tokens, indent=2))
        return

    if not extractor.screens:
        print(f"Warning: no screens detected in {proto_path}.", file=sys.stderr)
        print("Ensure sections/divs have id attributes containing: page, screen, view, panel, section, or tab", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Write design-tokens.json alongside contracts
    tokens = generate_tokens_json(extractor.css_vars)
    if tokens:
        tokens_path = out_dir / "design-tokens.json"
        tokens_path.write_text(json.dumps(tokens, indent=2))
        print(f"  design-tokens.json — {sum(len(v) for v in tokens.values())} tokens")

    # Write one YAML per screen
    written = 0
    for screen_id, screen_data in extractor.screens.items():
        yaml_content = screen_to_yaml(screen_data, str(proto_path))
        out_path = out_dir / f"{screen_id}.yaml"
        out_path.write_text(yaml_content)
        print(f"  {out_path} — draft ({len(screen_data['buttons'])} buttons, "
              f"{len(screen_data['forms'])} forms, {len(screen_data['tables'])} tables detected)")
        written += 1

    print(f"\nGenerated {written} contract drafts in {out_dir}/")
    print("Next: review each YAML, fill in TODOs, set status: approved")


if __name__ == "__main__":
    main()
