#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Running privacy/security preflight..."

failures=0
warnings=0

check_no_output() {
  local label="$1"
  local command="$2"
  local output

  output="$(eval "$command" || true)"
  if [ -n "$output" ]; then
    echo ""
    echo "ERROR: $label"
    echo "$output"
    failures=$((failures + 1))
  fi
}

warn_on_output() {
  local label="$1"
  local command="$2"
  local output

  output="$(eval "$command" || true)"
  if [ -n "$output" ]; then
    echo ""
    echo "REVIEW: $label"
    echo "$output"
    warnings=$((warnings + 1))
  fi
}

check_no_output \
  "Tracked private/generated artifact paths found. Move them out of the repo or update ignores before deploying." \
  \"git ls-files | rg -n '(^|/)(Ghost Pepper Meetings|transcription-lab|screenshots|Screenshots|\\.indexes|wikis|Reads)(/|$)|(^|/)(debug-log\\.json|cache-v6\\.json|cache-v6\\.json\\.enc|transcription-lab-index\\.json|transcription-lab-timings\\.json)$|(^|/)(20[0-9]{2}-[0-9]{2}-[0-9]{2})(/|$)|\\.(wav|m4a|mp3|caf|aiff|mov|mp4|webm)$'\"

check_no_output \
  "Likely credentials or private keys found in tracked files." \
  "git grep -n -I -E '(sk-ant-[A-Za-z0-9_-]{20,}|zo_sk_[A-Za-z0-9_-]{16,}|\\bpat[A-Za-z0-9]{14,}\\b|xox[baprs]-[A-Za-z0-9-]{20,}|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|Bearer [A-Za-z0-9._~+/=-]{20,}|-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----)' -- . ':!GhostPepper/Secrets.example'"

warn_on_output \
  "Sensitive debug/export affordances found. Confirm each one is local-only, intentional, and acceptable for this release." \
  "git grep -n -I -E 'Copy thread|full conversation|fullThreadDebugText|--- TRACE ---|recordSensitive|debugLogger\\?.*(rawTranscription|transcription|cleaned)' -- GhostPepper"

echo ""
echo "Network-capable code paths to review against the release allowlist:"
git grep -n -I -E 'URLSession|URLRequest|https?://' -- GhostPepper scripts project.yml appcast.xml README.md PRIVACY_AUDIT.md | sed -n '1,120p' || true

if [ "$failures" -ne 0 ]; then
  echo ""
  echo "Privacy/security preflight failed with $failures issue group(s)."
  exit 1
fi

if [ "$warnings" -ne 0 ]; then
  echo ""
  echo "Privacy/security preflight passed with $warnings review warning group(s)."
  echo "Review the warnings and fresh Codex audit findings before deploying."
  exit 0
fi

echo ""
echo "Privacy/security preflight passed."
