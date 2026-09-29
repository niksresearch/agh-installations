#!/usr/bin/env bash
# AGH Creative Suite — collect every output into one downloadable folder
#
# Gathers results scattered across the box (benchmark, video comparison, and each
# demo scenario) into a single dated, GPU-tagged folder, writes an INDEX.md that
# stitches all the individual reports together, and prints one scp command to pull
# the lot. Tag-by-GPU matters when comparing A100 vs H100 vs H200 — folders from
# different boxes never collide.
#
# Usage:
#   sudo bash collect_outputs.sh                 # copy everything (incl. final videos)
#   sudo SKIP_VIDEO=1 bash collect_outputs.sh    # skip large final .mp4s (metadata + stills only)
#   sudo TARBALL=1 bash collect_outputs.sh       # also produce a single .tar.gz
#
# Nothing is moved or deleted — originals stay where they are.
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log() { echo -e "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

# ── Paths ─────────────────────────────────────────────────────────────────────
[[ -f /etc/profile.d/agh-paths.sh ]] && source /etc/profile.d/agh-paths.sh
if [[ -z "${AGH_DATA:-}" ]]; then
  for c in /ephemeral /data /mnt/data; do mountpoint -q "$c" 2>/dev/null && { AGH_DATA="$c"; break; }; done
  AGH_DATA="${AGH_DATA:-/opt}"
fi
DATA_DIR="${AGH_DATA}"

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown-gpu")
GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 || echo "?")
# slug: "NVIDIA A100-SXM4-40GB" -> "A100-SXM4-40GB"
GPU_SLUG=$(echo "$GPU_NAME" | sed 's/NVIDIA //; s/[^A-Za-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
STAMP=$(date +%Y%m%d-%H%M)
DEST="${DATA_DIR}/agh-results-${GPU_SLUG}-${STAMP}"
mkdir -p "${DEST}"

log "${BOLD}════════════════════════════════════════════════════════════════${NC}"
log "${BOLD}  AGH — collecting outputs${NC}"
log "  GPU:  ${GPU_NAME} (${GPU_VRAM})"
log "  Dest: ${DEST}"
[[ "${SKIP_VIDEO:-0}" == "1" ]] && log "  ${YELLOW}SKIP_VIDEO=1 — large final videos excluded${NC}"
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"

copied_any=0

# copy_tree <label> <src-dir> <dest-subdir>
copy_tree() {
  local label="$1" src="$2" sub="$3"
  [[ -d "$src" ]] || { log "  ${YELLOW}○ ${label}: not found (${src})${NC}"; return; }
  mkdir -p "${DEST}/${sub}"
  if [[ "${SKIP_VIDEO:-0}" == "1" ]]; then
    # everything except the big final renders
    rsync -a --exclude='*.mp4' "$src"/ "${DEST}/${sub}/" 2>/dev/null \
      || cp -r "$src"/. "${DEST}/${sub}/" 2>/dev/null
    find "${DEST}/${sub}" -name '*.mp4' -delete 2>/dev/null
  else
    rsync -a "$src"/ "${DEST}/${sub}/" 2>/dev/null || cp -r "$src"/. "${DEST}/${sub}/" 2>/dev/null
  fi
  local n; n=$(find "${DEST}/${sub}" -type f 2>/dev/null | wc -l | tr -d ' ')
  local sz; sz=$(du -sh "${DEST}/${sub}" 2>/dev/null | cut -f1)
  log "  ${GREEN}✓${NC} ${label}: ${n} files (${sz})"
  copied_any=1
}

# ── Collect ───────────────────────────────────────────────────────────────────
copy_tree "benchmark"          "/tmp/agh-bench"                "benchmark"
copy_tree "video comparison"   "/tmp/agh-compare"              "compare"
copy_tree "smoke test"         "/tmp/agh-test"                 "smoke"
copy_tree "demo — campaign"    "${DATA_DIR}/agh-promo-v2"      "demos/campaign"
copy_tree "demo — cartoon"     "${DATA_DIR}/agh-cartoon"       "demos/cartoon"
copy_tree "demo — influencer"  "${DATA_DIR}/agh-influencer"    "demos/influencer"
copy_tree "demo — bundle1"     "${DATA_DIR}/agh-promo"         "demos/bundle1"

if [[ "$copied_any" != "1" ]]; then
  log "${YELLOW}Nothing found to collect. Run a demo/benchmark first.${NC}"
  exit 0
fi

# ── Build INDEX.md ────────────────────────────────────────────────────────────
INDEX="${DEST}/INDEX.md"
{
  echo "# AGH Creative Suite — Results"
  echo ""
  echo "- **GPU:**       ${GPU_NAME} (${GPU_VRAM})"
  echo "- **Host:**      $(hostname 2>/dev/null || echo n/a)"
  echo "- **Collected:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- **Driver:**    $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo n/a)"
  echo "- **OS:**        $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo n/a)"
  echo ""

  echo "## Contents"
  echo ""
  echo "| Folder | Files | Size |"
  echo "|---|---|---|"
  for d in benchmark compare smoke demos/campaign demos/cartoon demos/influencer demos/bundle1; do
    if [[ -d "${DEST}/${d}" ]]; then
      printf '| `%s` | %s | %s |\n' "$d" \
        "$(find "${DEST}/${d}" -type f 2>/dev/null | wc -l | tr -d ' ')" \
        "$(du -sh "${DEST}/${d}" 2>/dev/null | cut -f1)"
    fi
  done
  echo ""

  echo "## Final videos"
  echo ""
  found_video=0
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    found_video=1
    dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$v" 2>/dev/null)
    res=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$v" 2>/dev/null)
    printf -- '- `%s` — %s, %ss, %s\n' "${v#${DEST}/}" "${res:-?}" "${dur%.*}" "$(du -h "$v" 2>/dev/null | cut -f1)"
  done < <(find "${DEST}/demos" -maxdepth 2 -name '*.mp4' -size +1M 2>/dev/null | sort)
  [[ "$found_video" == "0" ]] && echo "_(none — SKIP_VIDEO was set, or no demo has completed)_"
  echo ""

  # Stitch in every report that exists
  for r in "${DEST}"/benchmark/results.md "${DEST}"/compare/COMPARE.md \
           "${DEST}"/demos/*/REPORT.md; do
    [[ -f "$r" ]] || continue
    echo ""
    echo "---"
    echo ""
    echo "## From \`${r#${DEST}/}\`"
    echo ""
    cat "$r"
  done
} > "${INDEX}" 2>/dev/null

log ""
log "  ${GREEN}✓${NC} INDEX.md written (all reports stitched together)"

# ── Optional tarball ──────────────────────────────────────────────────────────
if [[ "${TARBALL:-0}" == "1" ]]; then
  TAR="${DEST}.tar.gz"
  tar -czf "${TAR}" -C "$(dirname "${DEST}")" "$(basename "${DEST}")" 2>/dev/null \
    && log "  ${GREEN}✓${NC} tarball: ${TAR} ($(du -h "${TAR}" | cut -f1))"
fi

# ── Download instructions ─────────────────────────────────────────────────────
TOTAL=$(du -sh "${DEST}" 2>/dev/null | cut -f1)
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")

log ""
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"
log "  ${GREEN}${BOLD}Collected: ${DEST}  (${TOTAL})${NC}"
log ""
log "  ${BOLD}Download to your laptop — run this ON YOUR LAPTOP:${NC}"
log ""
if [[ "${TARBALL:-0}" == "1" ]]; then
log "    ${CYAN}scp -i <your-key.pem> ubuntu@${SERVER_IP}:${DEST}.tar.gz ~/Desktop/${NC}"
else
log "    ${CYAN}scp -r -i <your-key.pem> ubuntu@${SERVER_IP}:${DEST} ~/Desktop/${NC}"
fi
log ""
log "  Start with ${BOLD}INDEX.md${NC} — it has the GPU details and every report in one file."
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"
