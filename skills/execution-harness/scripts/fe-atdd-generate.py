#!/usr/bin/env python3
"""
fe-atdd-generate.py — ATDD gap fix: generate FAILING Playwright tests from approved UX contracts.

Subagent implementor receives these failing tests as context — their job is to make them pass,
not to figure out what to build. This is ATDD (Acceptance Test-Driven Development):
acceptance test written first (from contract), implementation follows.

Usage:
  python3 fe-atdd-generate.py ux-contracts/invoice-list.yaml --output tests/e2e/ux-contracts/
  python3 fe-atdd-generate.py ux-contracts/ --output tests/e2e/ux-contracts/  (batch)

Output: TypeScript Playwright test file per screen (status: FAILING before implementation)
"""

import sys
import re
import argparse
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: pyyaml not installed. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def slugify(text: str) -> str:
    return re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-')


def gen_loading_tests(screen: str, states: dict) -> str:
    if 'loading' not in states:
        return ''
    items = states['loading'].get('required', [])
    parts = [f"\ntest.describe('{screen} — loading state', () => {{"]
    parts.append(f"""  test.beforeEach(async ({{ page }}) => {{
    // Delay API response to observe loading state
    await page.route('**/api/**', async r => {{
      await new Promise(res => setTimeout(res, 3000))
      await r.continue()
    }})
  }})
""")
    for item in items:
        label = item.strip('- ').lower()
        if 'skeleton' in label or 'loading' in label or 'spinner' in label:
            parts.append(f"""  test('shows loading indicator: {item.strip()}', async ({{ page }}) => {{
    await page.goto('/{screen}')
    const skeleton = page.locator('.skeleton, .skeleton-row, [data-testid*="skeleton"], [aria-busy="true"]')
    await expect(skeleton.first()).toBeVisible({{ timeout: 2000 }})
  }})
""")
        elif 'disabled' in label or 'button' in label:
            parts.append(f"""  test('disables action buttons while loading', async ({{ page }}) => {{
    await page.goto('/{screen}')
    const buttons = page.getByRole('button')
    const firstBtn = buttons.first()
    if (await firstBtn.count() > 0) {{
      await expect(firstBtn).toBeDisabled({{ timeout: 2000 }})
    }}
  }})
""")
    parts.append('})')
    return '\n'.join(parts)


def gen_empty_tests(screen: str, states: dict) -> str:
    if 'empty' not in states:
        return ''
    items = states['empty'].get('required', [])
    parts = [f"\ntest.describe('{screen} — empty state', () => {{"]
    parts.append(f"""  test.beforeEach(async ({{ page }}) => {{
    await page.route('**/api/**', r => r.fulfill({{ json: [] }}))
  }})
""")
    for item in items:
        label = item.strip('- ').lower()
        if 'cta' in label or 'button' in label or 'action' in label:
            btn_name = re.search(r'"([^"]+)"', item)
            btn_pattern = btn_name.group(1) if btn_name else 'action'
            parts.append(f"""  test('empty state has actionable CTA', async ({{ page }}) => {{
    await page.goto('/{screen}')
    // Find CTA by role — not by CSS class
    const cta = page.getByRole('button', {{ name: /{re.escape(btn_pattern)}/i }}).or(
      page.getByRole('link', {{ name: /{re.escape(btn_pattern)}/i }})
    )
    await expect(cta).toBeVisible()
  }})
""")
        elif 'text' in label or 'deskriptif' in label or 'descriptive' in label:
            parts.append(f"""  test('empty state has descriptive text (not just No data)', async ({{ page }}) => {{
    await page.goto('/{screen}')
    const body = await page.textContent('body')
    expect(body).not.toMatch(/^no data$/im)
    expect(body).not.toContain('undefined')
  }})
""")
    parts.append('})')
    return '\n'.join(parts)


def gen_error_tests(screen: str, states: dict) -> str:
    if 'error' not in states:
        return ''
    parts = [f"\ntest.describe('{screen} — error state', () => {{"]
    parts.append(f"""  test.beforeEach(async ({{ page }}) => {{
    await page.route('**/api/**', r => r.fulfill({{ status: 500, json: {{ message: 'Internal Error' }} }}))
  }})

  test('shows inline error (not full-page redirect)', async ({{ page }}) => {{
    const navPromise = page.waitForNavigation({{ timeout: 2000 }}).catch(() => null)
    await page.goto('/{screen}')
    const nav = await navPromise
    expect(nav).toBeNull() // no navigation = error shown inline
    const errorEl = page.locator('[role="alert"], .error-banner, [data-testid*="error"]')
    await expect(errorEl.first()).toBeVisible()
  }})

  test('never shows raw error text or undefined', async ({{ page }}) => {{
    await page.goto('/{screen}')
    const body = await page.textContent('body')
    expect(body).not.toContain('undefined')
    expect(body).not.toMatch(/Error:.*at.*\\.js/i) // no stack trace
    expect(body).not.toContain('Internal Server Error')
  }})

  test('provides recovery action (retry button or link)', async ({{ page }}) => {{
    await page.goto('/{screen}')
    const retry = page.getByRole('button', {{ name: /retry|coba lagi|refresh/i }}).or(
      page.getByRole('link', {{ name: /retry|coba lagi/i }})
    )
    await expect(retry).toBeVisible()
  }})
}})
""")
    return '\n'.join(parts)


def gen_journey_tests(screen: str, journeys: list) -> str:
    if not journeys:
        return ''
    parts = []
    for journey in journeys:
        jid = journey.get('id', 'journey')
        steps = journey.get('steps', [])
        parts.append(f"\ntest('{screen} — journey: {jid}', async ({{ page }}) => {{")
        parts.append(f"  await page.goto('/{screen}')")
        for step in steps:
            if step.startswith('trigger:'):
                action = step.replace('trigger:', '').strip()
                if 'click' in action.lower():
                    btn = re.search(r'"([^"]+)"', action)
                    if btn:
                        parts.append(f"  await page.getByRole('button', {{ name: /{re.escape(btn.group(1))}/i }}).click()")
                    else:
                        parts.append(f"  // TODO: implement trigger — {action}")
            elif step.startswith('expect:'):
                expectation = step.replace('expect:', '').strip()
                if 'modal' in expectation.lower() or 'dialog' in expectation.lower():
                    parts.append(f"  await expect(page.getByRole('dialog')).toBeVisible()")
                elif 'toast' in expectation.lower() or 'success' in expectation.lower():
                    parts.append(f"  await expect(page.getByRole('status').or(page.locator('[data-testid*=\"toast\"]'))).toBeVisible()")
                elif 'close' in expectation.lower():
                    parts.append(f"  await expect(page.getByRole('dialog')).not.toBeVisible()")
                else:
                    parts.append(f"  // TODO: assert — {expectation}")
            elif step.startswith('action:'):
                action = step.replace('action:', '').strip()
                parts.append(f"  // TODO: perform — {action}")
        parts.append('})')
    return '\n'.join(parts)


def gen_rubric_tests(screen: str, rubric: dict) -> str:
    if not rubric:
        return ''
    parts = [f"\ntest.describe('{screen} — production-grade rubric', () => {{"]
    if rubric.get('error_never_raw'):
        parts.append(f"""  test('never exposes raw errors or undefined to user', async ({{ page }}) => {{
    // Check with 500 error
    await page.route('**/api/**', r => r.fulfill({{ status: 500, json: {{}} }}))
    await page.goto('/{screen}')
    const body = await page.textContent('body')
    expect(body).not.toContain('undefined')
    expect(body).not.toMatch(/\\.js:\\d+:\\d+/)
  }})
""")
    if rubric.get('keyboard_navigable'):
        parts.append(f"""  test('primary actions reachable via keyboard (Tab)', async ({{ page }}) => {{
    await page.goto('/{screen}')
    await page.keyboard.press('Tab')
    const focused = await page.evaluate(() => document.activeElement?.tagName)
    expect(['BUTTON', 'A', 'INPUT', 'SELECT', 'TEXTAREA']).toContain(focused)
  }})
""")
    parts.append('})')
    return '\n'.join(parts)


def generate_test_file(contract_path: Path) -> str:
    with open(contract_path) as f:
        contract = yaml.safe_load(f)

    if contract.get('status', 'draft') != 'approved':
        return None

    screen = contract.get('screen', contract_path.stem)
    states = contract.get('states', {})
    journeys = contract.get('journeys', [])
    rubric = contract.get('production_grade_rubric', {})

    header = f"""// AUTO-GENERATED by fe-atdd-generate.py from {contract_path.name}
// Status: FAILING — implementor's job is to make all tests pass
// Source contract: {contract_path}
// DO NOT edit manually — regenerate with fe-atdd-generate.py

import {{ test, expect }} from '@playwright/test'

// Screen: {screen}
// These tests define WHAT the screen must do, derived from the approved UX contract.
// All tests fail before implementation. Subagent: make them green.
"""
    body = ''
    body += gen_loading_tests(screen, states)
    body += gen_empty_tests(screen, states)
    body += gen_error_tests(screen, states)
    body += gen_journey_tests(screen, journeys)
    body += gen_rubric_tests(screen, rubric)

    return header + body


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('input', help='YAML contract file or directory of YAML files')
    parser.add_argument('--output', '-o', default='tests/e2e/ux-contracts',
                        help='Output directory for generated Playwright test files')
    args = parser.parse_args()

    input_path = Path(args.input)
    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    paths = list(input_path.glob('*.yaml')) if input_path.is_dir() else [input_path]
    generated = 0
    skipped = 0

    for p in sorted(paths):
        if p.name == 'design-tokens.json':
            continue
        try:
            content = generate_test_file(p)
        except Exception as e:
            print(f"  SKIP {p.name}: {e}", file=sys.stderr)
            skipped += 1
            continue

        if content is None:
            print(f"  SKIP {p.name}: status is not 'approved' — set status: approved first")
            skipped += 1
            continue

        out_path = out_dir / f"{p.stem}.spec.ts"
        out_path.write_text(content)
        test_count = content.count('test(') + content.count("test.describe(")
        print(f"  {out_path} — {test_count} test blocks (all FAILING until implementation)")
        generated += 1

    print(f"\nGenerated {generated} test files, skipped {skipped}")
    print("Next: inject test paths into subagent context bundle → implementor makes them green")


if __name__ == '__main__':
    main()
