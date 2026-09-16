#!/usr/bin/env bash
# AGH Creative Suite — video model comparison (LTX vs HunyuanVideo vs CogVideoX vs Wan2.1)
#
# Generates the SAME prompt on every installed video engine, at matched settings
# where possible, and reports time / peak VRAM / output spec side by side —
# so you can judge quality vs speed vs cost per engine on THIS GPU.
#
# Usage:
#   sudo bash compare_video_models.sh                    # all installed engines, lite settings
#   sudo bash compare_video_models.sh heavy              # bigger/longer settings
#   sudo bash compare_video_models.sh lite ltx hunyuan   # only named engines
#   sudo bash compare_video_models.sh --prompt "..."     # custom prompt
#
# Engines: ltx hunyuan cogvideo wan21
#   wan21 needs ~73GB VRAM — auto-skipped on <75GB cards unless FORCE_WAN=1.
#
# Outputs:
#   /tmp/agh-compare/<engine>.mp4
#   /tmp/agh-compare/compare.log     (clean run log)
#   /tmp/agh-compare/COMPARE.md      (side-by-side report)
set -uo pipefail

OUT=/tmp/agh-compare
LOG="${OUT}/compare.log"
mkdir -p "${OUT}"; : > "${LOG}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log() { echo -e "$*"; echo -e "$(echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g')" >> "${LOG}"; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
[[ -f /etc/profile.d/agh-paths.sh ]] && source /etc/profile.d/agh-paths.sh
if [[ -z "${AGH_MODELS:-}" ]]; then
  for c in /ephemeral /data /mnt/data; do mountpoint -q "$c" 2>/dev/null && { AGH_MODELS="$c/models"; break; }; done
  AGH_MODELS="${AGH_MODELS:-/opt/models}"
fi
MODELS_DIR="${AGH_MODELS}"

# Robust pod pick: the sleep-infinity whose namespace actually has the tools
# (a stale duplicate gives 'cannot open /proc/<pid>/ns/mnt' on every nsenter call).
POD_PID=""
for _pid in $(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}'); do
  if nsenter -t "$_pid" -m -- test -d /opt/agh-video-env 2>/dev/null; then POD_PID="$_pid"; break; fi
done
[[ -n "$POD_PID" ]] || { echo "No pod with /opt/agh-video-env found. Is setup done and the pod running?"; exit 1; }
inpod() { nsenter -t "$POD_PID" -m -- bash -c "$1"; }

# ── Args ──────────────────────────────────────────────────────────────────────
MODE="lite"; PROMPT=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    lite|heavy) MODE="$1"; shift ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ -z "$PROMPT" ]] && PROMPT="A futuristic AI creative studio, holographic screens displaying glowing artwork, blue and purple particles drifting through the air, slow cinematic camera push forward, photorealistic, smooth motion, 4K"

ALL_ENGINES=(ltx hunyuan cogvideo wan21)
[[ ${#ARGS[@]} -eq 0 ]] && ENGINES=("${ALL_ENGINES[@]}") || ENGINES=("${ARGS[@]}")

if [[ "$MODE" == "heavy" ]]; then
  LTX_FRAMES=121; LTX_STEPS=30; LTX_W=768;  LTX_H=512
  HUN_FRAMES=129; HUN_STEPS=30; HUN_W=960;  HUN_H=544
  COG_FRAMES=49;  COG_STEPS=50
  WAN_FRAMES=161; WAN_STEPS=40; WAN_SIZE="1280*720"
else
  LTX_FRAMES=49;  LTX_STEPS=20; LTX_W=768;  LTX_H=512
  HUN_FRAMES=49;  HUN_STEPS=20; HUN_W=512;  HUN_H=320
  COG_FRAMES=49;  COG_STEPS=20
  WAN_FRAMES=81;  WAN_STEPS=20; WAN_SIZE="1280*720"
fi

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "GPU")
GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)

start_vram() { : > "${OUT}/.vram"; ( while :; do nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 >> "${OUT}/.vram"; sleep 1; done ) & echo $!; }
stop_vram()  { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; sort -n "${OUT}/.vram" 2>/dev/null | tail -1; }
vid_spec()   { inpod "ffprobe -v error -select_streams v:0 -show_entries stream=width,height,nb_frames,r_frame_rate -show_entries format=duration -of default=nw=1 '$1' 2>/dev/null" | tr '\n' ' '; }

declare -A ENGINE_TIME ENGINE_VRAM ENGINE_STATUS ENGINE_SPEC ENGINE_SETTINGS

log "${BOLD}════════════════════════════════════════════════════════════════${NC}"
log "${BOLD}  AGH video model comparison${NC}"
log "  GPU:      ${GPU_NAME}  (${GPU_VRAM_MB} MiB)"
log "  Mode:     ${MODE}"
log "  Engines:  ${ENGINES[*]}"
log "  Prompt:   ${PROMPT}"
log "  Outputs:  ${OUT}/"
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"

run_engine() {
  local name="$1" script="$2" settings="$3" outfile="${OUT}/${1}.mp4"
  log "${CYAN}▶ ${name}${NC} — ${settings}"
  local vp t0 t1 el
  vp=$(start_vram); t0=$(date +%s)
  inpod "$script" >/dev/null 2>>"${OUT}/${name}.err"
  t1=$(date +%s); el=$(( t1 - t0 )); ENGINE_TIME[$name]=$el
  ENGINE_VRAM[$name]=$(stop_vram "$vp")
  ENGINE_SETTINGS[$name]="$settings"
  if [[ -s "$outfile" ]]; then
    ENGINE_STATUS[$name]="OK"
    ENGINE_SPEC[$name]=$(vid_spec "$outfile")
    log "  ${GREEN}✓ ${name} done${NC} (${el}s, peak ${ENGINE_VRAM[$name]}MB) -> ${outfile}"
  else
    ENGINE_STATUS[$name]="FAIL"
    log "  ${RED}✗ ${name} failed${NC} (${el}s) — see ${OUT}/${name}.err"
  fi
}

for eng in "${ENGINES[@]}"; do
  case "$eng" in

    ltx)
      if [[ ! -d /opt/agh-video-env ]]; then log "${YELLOW}○ ltx: AGH Video Studio not installed — skipping${NC}"; ENGINE_STATUS[ltx]="SKIP"; continue; fi
      run_engine ltx "
source /opt/agh-video-env/bin/activate
export HF_HOME=${MODELS_DIR}/hf-cache
python - <<'PY' 2>>${OUT}/ltx.err
import torch
from diffusers import LTXPipeline
from diffusers.utils import export_to_video
pipe=LTXPipeline.from_pretrained('Lightricks/LTX-Video', torch_dtype=torch.bfloat16)
pipe.enable_model_cpu_offload()
v=pipe(prompt='${PROMPT}', width=${LTX_W}, height=${LTX_H}, num_frames=${LTX_FRAMES}, num_inference_steps=${LTX_STEPS}).frames[0]
export_to_video(v, '${OUT}/ltx.mp4', fps=24)
print('ok')
PY" "frames:${LTX_FRAMES} size:${LTX_W}x${LTX_H} steps:${LTX_STEPS} fps:24"
      ;;

    hunyuan)
      if [[ ! -d /opt/agh-video-env ]]; then log "${YELLOW}○ hunyuan: AGH Video Studio not installed — skipping${NC}"; ENGINE_STATUS[hunyuan]="SKIP"; continue; fi
      run_engine hunyuan "
source /opt/agh-video-env/bin/activate
export HF_HOME=${MODELS_DIR}/hf-cache
python - <<'PY' 2>>${OUT}/hunyuan.err
import torch
from diffusers import HunyuanVideoPipeline, HunyuanVideoTransformer3DModel
from diffusers.utils import export_to_video
repo='hunyuanvideo-community/HunyuanVideo'
tr=HunyuanVideoTransformer3DModel.from_pretrained(repo, subfolder='transformer', torch_dtype=torch.bfloat16)
pipe=HunyuanVideoPipeline.from_pretrained(repo, transformer=tr, torch_dtype=torch.float16)
pipe.enable_model_cpu_offload(); pipe.vae.enable_tiling()
v=pipe(prompt='${PROMPT}', num_frames=${HUN_FRAMES}, height=${HUN_H}, width=${HUN_W}, num_inference_steps=${HUN_STEPS}).frames[0]
export_to_video(v, '${OUT}/hunyuan.mp4', fps=15)
print('ok')
PY" "frames:${HUN_FRAMES} size:${HUN_W}x${HUN_H} steps:${HUN_STEPS} fps:15"
      ;;

    cogvideo)
      if [[ ! -d /opt/agh-video-env ]]; then log "${YELLOW}○ cogvideo: AGH Video Studio not installed — skipping${NC}"; ENGINE_STATUS[cogvideo]="SKIP"; continue; fi
      run_engine cogvideo "
source /opt/agh-video-env/bin/activate
export HF_HOME=${MODELS_DIR}/hf-cache
python - <<'PY' 2>>${OUT}/cogvideo.err
import torch
from diffusers import CogVideoXPipeline
from diffusers.utils import export_to_video
pipe=CogVideoXPipeline.from_pretrained('THUDM/CogVideoX-5b', torch_dtype=torch.bfloat16)
pipe.enable_model_cpu_offload(); pipe.vae.enable_tiling()
v=pipe(prompt='${PROMPT}', num_frames=${COG_FRAMES}, guidance_scale=6.0, num_inference_steps=${COG_STEPS}).frames[0]
export_to_video(v, '${OUT}/cogvideo.mp4', fps=8)
print('ok')
PY" "frames:${COG_FRAMES} steps:${COG_STEPS} fps:8"
      ;;

    wan21)
      if [[ ! -d /opt/Wan2.1 ]]; then log "${YELLOW}○ wan21: not installed — skipping${NC}"; ENGINE_STATUS[wan21]="SKIP"; continue; fi
      if [[ "${GPU_VRAM_MB:-0}" -lt 75000 && "${FORCE_WAN:-0}" != "1" ]]; then
        log "${YELLOW}○ wan21: GPU has ${GPU_VRAM_MB}MB (<75GB), Wan2.1-14B needs ~73GB — skipping (set FORCE_WAN=1 to try anyway)${NC}"
        ENGINE_STATUS[wan21]="SKIP"; continue
      fi
      run_engine wan21 "
source /opt/wan21-env/bin/activate
cd /opt/Wan2.1
python generate.py --task t2v-14B --size ${WAN_SIZE} \
  --ckpt_dir ${MODELS_DIR}/wan21 \
  --frame_num ${WAN_FRAMES} \
  --sample_steps ${WAN_STEPS} --sample_guide_scale 6.0 \
  --prompt '${PROMPT}' \
  --save_file ${OUT}/wan21.mp4 2>>${OUT}/wan21.err
" "frames:${WAN_FRAMES} size:${WAN_SIZE} steps:${WAN_STEPS}"
      ;;

    *) log "${YELLOW}skip unknown engine: ${eng}${NC}" ;;
  esac
done

# ── Report ────────────────────────────────────────────────────────────────────
REPORT="${OUT}/COMPARE.md"
{
  echo "# AGH Video Model Comparison"
  echo ""
  echo "- **Created:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- **GPU:**     ${GPU_NAME} (${GPU_VRAM_MB} MiB)"
  echo "- **Prompt:**  ${PROMPT}"
  echo ""
  echo "| Engine | Status | Settings | Time | Peak VRAM | Output spec |"
  echo "|---|---|---|---|---|---|"
  for eng in "${ENGINES[@]}"; do
    st="${ENGINE_STATUS[$eng]:-SKIP}"
    printf '| %s | %s | %s | %s | %s | %s |\n' \
      "$eng" "$st" \
      "${ENGINE_SETTINGS[$eng]:-—}" \
      "${ENGINE_TIME[$eng]:+${ENGINE_TIME[$eng]}s}" \
      "${ENGINE_VRAM[$eng]:+${ENGINE_VRAM[$eng]}MB}" \
      "${ENGINE_SPEC[$eng]:-—}"
  done
  echo ""
  echo "## Files"
  for eng in "${ENGINES[@]}"; do
    [[ -s "${OUT}/${eng}.mp4" ]] && echo "- \`${OUT}/${eng}.mp4\`"
  done
  echo ""
  echo "_Same prompt, matched settings per engine's practical limits on this GPU._"
} > "${REPORT}"

log ""
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"
log "  Report: ${REPORT}"
log "  Clips:  ${OUT}/*.mp4"
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"
