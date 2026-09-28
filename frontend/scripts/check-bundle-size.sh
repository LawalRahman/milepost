#!/usr/bin/env bash
#
# Compare the built JavaScript bundle against the recorded baseline.
# The budget allows a small percentage of growth so CI fails on meaningful
# regressions, not on the existing bundle size itself.
#
# Prints two Markdown tables — the total against the budget, then the largest
# chunks — and prints both before failing, so the summary shows what grew
# on exactly the run where someone needs to know.
#
#   ./scripts/check-bundle-size.sh [budget-file] [dist-assets-dir]

set -euo pipefail

# How many chunks the composition table lists.
TOP_CHUNKS=10

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUDGET_FILE="${1:-$ROOT/bundle-budget.json}"
ASSETS_DIR="${2:-$ROOT/dist/assets}"

[[ -f "$BUDGET_FILE" ]] || { echo "budget file not found: $BUDGET_FILE" >&2; exit 1; }
[[ -d "$ASSETS_DIR" ]] || { echo "frontend assets directory not found: $ASSETS_DIR" >&2; exit 1; }

read -r baseline growth_percent budget < <(
  node -e '
const fs = require("node:fs");
const frontend = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).frontend;
const baseline = Number.parseInt(frontend.baseline_bytes, 10);
const growthPercent = Number(frontend.allowed_growth_percent);
const budget = Math.floor(baseline * (1 + growthPercent / 100));
console.log(baseline, growthPercent, budget);
' "$BUDGET_FILE"
)

# One "<bytes> <gzip bytes> <name>" line per chunk. `wc -c <` rather than
# `stat`, whose flags differ between GNU and BSD, and a plain loop rather than
# `mapfile`, which the bash 3.2 that macOS ships does not have — so this runs
# locally as well as in CI.
chunks=""
size=0
gzip_size=0
while IFS= read -r file; do
  bytes=$(wc -c < "$file" | tr -d ' ')
  gz=$(gzip -c "$file" | wc -c | tr -d ' ')
  size=$((size + bytes))
  gzip_size=$((gzip_size + gz))
  chunks+="$bytes $gz $(basename "$file")"$'\n'
done < <(find "$ASSETS_DIR" -maxdepth 1 -type f -name '*.js' | sort)

if [[ -z "$chunks" ]]; then
  echo "no JavaScript assets found in $ASSETS_DIR" >&2
  exit 1
fi
chunk_count=$(printf '%s' "$chunks" | wc -l | tr -d ' ')

delta=$((size - baseline))
budget_delta=$((size - budget))
over_budget=0
(( size > budget )) && over_budget=1

echo "| frontend bundle | size (bytes) | gzip size (bytes) | baseline | allowed growth | budget | delta vs baseline |"
echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"
if (( over_budget )); then
  echo "| JavaScript assets | **$size** | $gzip_size | $baseline | ${growth_percent}% | $budget | **+$delta** |"
elif (( delta > 0 )); then
  echo "| JavaScript assets | $size | $gzip_size | $baseline | ${growth_percent}% | $budget | +$delta |"
else
  echo "| JavaScript assets | $size | $gzip_size | $baseline | ${growth_percent}% | $budget | $delta |"
fi

echo
echo "#### Largest chunks ($(( chunk_count < TOP_CHUNKS ? chunk_count : TOP_CHUNKS )) of $chunk_count)"
echo
echo "| chunk | size (bytes) | gzip size (bytes) | share of total |"
echo "| --- | ---: | ---: | ---: |"
# awk stops reading after the limit instead of `head`, which could close the
# pipe early and trip pipefail.
printf '%s' "$chunks" | sort -k1,1nr -k3,3 | awk -v top="$TOP_CHUNKS" -v total="$size" '
  NR <= top { printf "| `%s` | %d | %d | %.1f%% |\n", $3, $1, $2, 100 * $1 / total }
'

if (( over_budget )); then
  echo
  echo "Frontend bundle size budget exceeded by $budget_delta bytes." >&2
  echo "Update bundle-budget.json only after confirming the growth is intentional." >&2
  exit 1
fi
