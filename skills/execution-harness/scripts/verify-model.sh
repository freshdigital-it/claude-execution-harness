#!/usr/bin/env bash
# Resolve the verification/QA model from the implementation model + policy.
#
# Usage: verify-model.sh <impl_model> [task_class]
#   impl_model: haiku | sonnet | opus  (the model the implementer used)
#   task_class: security-core | business | bugfix | fe-visual | ... (for floor rules)
#
# Env: HARNESS_VERIFY_POLICY
#   one-below   (default) verifier = implementer minus one tier, with a per-class floor
#   equal                 verifier = same tier as implementer
#   fixed:<model>         verifier = always this model (e.g. fixed:sonnet)
#
# Stdout: haiku | sonnet | opus
#
# Rationale: generator/verifier asymmetry. A strong implementer (Opus) can be
# checked by a capable-but-cheaper verifier (Sonnet). Security and business logic
# never drop below Sonnet — the floor protects correctness where it matters.

set -euo pipefail

IMPL_MODEL="${1:?usage: verify-model.sh <impl_model> [task_class]}"
TASK_CLASS="${2:-business}"
POLICY="${HARNESS_VERIFY_POLICY:-one-below}"

# ── Model ladder ───────────────────────────────────────────────────────────────
tier_of() {
    case "$1" in
        haiku)  echo 1 ;;
        sonnet) echo 2 ;;
        opus)   echo 3 ;;
        *) echo "verify-model: unknown model '$1'" >&2; exit 2 ;;
    esac
}
model_of() {
    case "$1" in
        1) echo haiku ;;
        2) echo sonnet ;;
        *) echo opus ;;   # clamp anything >=3 to opus
    esac
}

# ── fixed:<model> ──────────────────────────────────────────────────────────────
if [[ "$POLICY" == fixed:* ]]; then
    FIXED="${POLICY#fixed:}"
    tier_of "$FIXED" >/dev/null   # validate
    echo "$FIXED"
    exit 0
fi

IMPL_TIER=$(tier_of "$IMPL_MODEL")

# ── equal ──────────────────────────────────────────────────────────────────────
if [[ "$POLICY" == "equal" ]]; then
    echo "$IMPL_MODEL"
    exit 0
fi

# ── one-below (default) ────────────────────────────────────────────────────────
if [[ "$POLICY" != "one-below" ]]; then
    echo "verify-model: unknown HARNESS_VERIFY_POLICY '$POLICY' (use one-below|equal|fixed:<model>)" >&2
    exit 2
fi

VERIFY_TIER=$(( IMPL_TIER - 1 ))
(( VERIFY_TIER < 1 )) && VERIFY_TIER=1

# Per-class floor. Only genuinely mechanical work may verify at Haiku — and those
# classes use deterministic gates (tsc/linter), so they rarely call this resolver.
# Everything that spawns an LLM verifier (security adversarial, fe-visual GAN,
# business/bugfix correctness) floors at Sonnet. Net effect of one-below: it bites
# only when the implementer was Opus → verifier drops to Sonnet.
case "$TASK_CLASS" in
    mechanical-fan|refactor|fe-mechanical)
        : ;;   # no floor — Haiku verification acceptable
    *)
        (( VERIFY_TIER < 2 )) && VERIFY_TIER=2 ;;
esac

model_of "$VERIFY_TIER"
