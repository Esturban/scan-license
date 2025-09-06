#!/usr/bin/env bash
# Quiet GPL scanner for mixed repos
# Usage:
#   ./scan-gpl.sh /path/to/repos               # summary of hits only
#   ./scan-gpl.sh --deep /path/to/repos        # include dependency scans
#   ./scan-gpl.sh --verbose /path/to/repos     # print details per hit
#   ./scan-gpl.sh --report csv /path           # write report.csv
#   ./scan-gpl.sh --report md /path            # write report.md

set -euo pipefail

BASE_DIR="."
DEEP=0
VERBOSE=0
REPORT=""

for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=1 ;;
    --verbose) VERBOSE=1 ;;
    --report) REPORT="csv" ;;   # default csv if flag used without value
    csv|md) REPORT="$arg" ;;
    *) BASE_DIR="$arg" ;;
  esac
done

if [ ! -d "$BASE_DIR" ]; then
  echo "Base directory not found: $BASE_DIR" >&2; exit 1
fi

# Tools
HAS_RG=0; command -v rg >/dev/null 2>&1 && HAS_RG=1
RG() { if [ $HAS_RG -eq 1 ]; then rg -i -n --max-count=1 --no-heading "$@"; else grep -Iri --line-number --max-count=1 "$@"; fi; }

PRUNE_DIRS=".git node_modules .venv venv dist build .cache .mypy_cache .pytest_cache __pycache__ .next .turbo target .gradle .idea"
GPL_PATTERN='(gpl-?3(\.0)?|gnu general public license.*3)'

# Collect candidates = dirs that look like project roots
find_candidates() {
  local prunes=()
  for d in $PRUNE_DIRS; do prunes+=( -name "$d" -prune -o ); done
  # shellcheck disable=SC2016
  find "$BASE_DIR" \( "${prunes[@]}" -false \) -o -type d -print 2>/dev/null \
  | while read -r d; do
      [ -f "$d/package.json" ] || [ -f "$d/requirements.txt" ] || [ -f "$d/pyproject.toml" ] || \
      [ -f "$d/go.mod" ] || ls "$d"/LICENSE* "$d"/COPYING* >/dev/null 2>&1 || \
      [ -d "$d/.git" ] || continue
      echo "$d"
    done | sort -u
}

# Reporting buffer
RESULTS=() # lines: "path|signal|detail"

scan_one() {
  local project="$1"
  local hit=0

  # 1) License files (only show if GPL-3 is in header/body)
  if ls "$project"/LICENSE* "$project"/COPYING* >/dev/null 2>&1; then
    if RG -E "$GPL_PATTERN" "$project"/LICENSE* "$project"/COPYING* >/dev/null 2>&1; then
      hit=1; RESULTS+=("$project|license|LICENSE/COPYING mentions GPL-3")
      [ $VERBOSE -eq 1 ] && echo "== $project == LICENSE → GPL-3"
    fi
  fi

  # 2) Static source scan (skip heavy dirs; avoid binary noise)
  if RG -E "$GPL_PATTERN" "$project" \
      --hidden 2>/dev/null \
      | grep -vE "/($PRUNE_DIRS)/" | head -n1 >/dev/null; then
    hit=1; RESULTS+=("$project|source|string match in source (GPL-3)")
    [ $VERBOSE -eq 1 ] && echo "== $project == source → GPL-3 string"
  fi

  # 3) Frappe/ERPNext hints
  if [ -f "$project/apps.txt" ] || [ -f "$project/sites/apps.txt" ]; then
    if grep -qi "erpnext" "$project"/apps.txt 2>/dev/null || grep -qi "erpnext" "$project"/sites/apps.txt 2>/dev/null; then
      hit=1; RESULTS+=("$project|frappe|apps.txt references ERPNext (GPL-3)")
      [ $VERBOSE -eq 1 ] && echo "== $project == ERPNext in apps.txt"
    fi
  fi
  if [ -f "$project/requirements.txt" ]; then
    if grep -qi "^erpnext" "$project/requirements.txt" 2>/dev/null; then
      hit=1; RESULTS+=("$project|frappe|requirements.txt has erpnext (GPL-3)")
      [ $VERBOSE -eq 1 ] && echo "== $project == requirements.txt → erpnext"
    fi
  fi
  if [ -f "$project/pyproject.toml" ]; then
    if grep -qi 'name *= *"erpnext"' "$project/pyproject.toml" 2>/dev/null; then
      hit=1; RESULTS+=("$project|frappe|pyproject references erpnext (GPL-3)")
      [ $VERBOSE -eq 1 ] && echo "== $project == pyproject → erpnext"
    fi
  fi

  # 4) Optional dependency scans (quiet)
  if [ $DEEP -eq 1 ]; then
    # Python
    if [ -f "$project/requirements.txt" ] || [ -f "$project/pyproject.toml" ]; then
      if command -v pip-licenses >/dev/null 2>&1; then
        if ( cd "$project" && pip-licenses --from=mixed --with-urls 2>/dev/null | RG -E "gpl" >/dev/null ); then
          hit=1; RESULTS+=("$project|deps-python|pip-licenses found GPL dep")
          [ $VERBOSE -eq 1 ] && echo "== $project == deps(py) → GPL"
        fi
      elif [ $VERBOSE -eq 1 ]; then
        echo "== $project == deps(py) skipped (pip-licenses not installed)"
      fi
    fi
    # Node
    if [ -f "$project/package.json" ]; then
      if command -v npx >/dev/null 2>&1; then
        if ( cd "$project" && npx -y license-checker --summary --production 1>/dev/null 2>/dev/null; \
             cd "$project" && npx -y license-checker --production --json 2>/dev/null \
             | RG -E '"license": *"[^"]*gpl' >/dev/null ); then
          hit=1; RESULTS+=("$project|deps-node|license-checker found GPL dep")
          [ $VERBOSE -eq 1 ] && echo "== $project == deps(node) → GPL"
        fi
      elif [ $VERBOSE -eq 1 ]; then
        echo "== $project == deps(node) skipped (npx not available)"
      fi
    fi
  fi

  # Summary print if verbose
  if [ $VERBOSE -eq 1 ] && [ $hit -eq 0 ]; then
    echo "== $project == OK (no GPL-3 signals)"
  fi
}

echo "Scanning (quiet)…"
mapfile -t CANDS < <(find_candidates)
for d in "${CANDS[@]}"; do scan_one "$d"; done

# Emit summary (hits only)
if [ ${#RESULTS[@]} -eq 0 ]; then
  echo "No GPL-3 signals found."
else
  echo ""
  echo "=== GPL-3 signals (summary) ==="
  printf "%s\n" "${RESULTS[@]}" | awk -F'|' '{printf "- %s [%s]: %s\n", $1, $2, $3}' | sort -u
fi

# Optional report
if [ -n "$REPORT" ]; then
  OUT="report.$REPORT"
  if [ "$REPORT" = "csv" ]; then
    { echo "project,signal,detail"; printf "%s\n" "${RESULTS[@]}" | sed 's/|/,/g'; } > "$OUT"
  else
    { echo "## GPL-3 Signals"; printf "%s\n" "${RESULTS[@]}" | awk -F'|' '{printf "- **%s** — `%s`: %s\n",$1,$2,$3}'; } > "$OUT"
  fi
  echo "Report written: $OUT"
fi
