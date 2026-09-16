#!/usr/bin/env bash
# AGH Creative Suite — smoke test (all bundles)
#
# Runs a tiny, fast job against each installed tool to confirm it works BEFORE
# running the full promo demo. Writes a clean PASS/FAIL/SKIP log with timing.
# Tools not installed in the current bundle are SKIPPED (not failed).
#
# Usage:
#   sudo bash smoke_test.sh                    # lite mode, core tests (image upscale music voice)
#   sudo bash smoke_test.sh lite all           # lite, Bundle 1/2 tools (+ wan21 hunyuan)
#   sudo bash smoke_test.sh heavy all          # BIG sizes + long clips, Bundle 1/2 tools
#   sudo bash smoke_test.sh lite b3            # lite, ALL tools incl. Bundle 3 (ltx cogvideo a1111)
#   sudo bash smoke_test.sh heavy b3           # full Bundle 3 real-load run
#   sudo bash smoke_test.sh heavy image music  # big image + 2-min music only
#
# Arg 1 (optional): lite | heavy   — size/length profile (default lite)
# Remaining args  : test names, or "all" (B1/B2 tools) or "b3" (all incl. Bundle 3).
#                   Default (none) = image upscale music voice
# Test names      : image upscale music voice wan21 hunyuan ltx cogvideo a1111 wan22 mochi
#                   (wan22/mochi only appear when installed — 80GB+ GPU, see setup)
#
#   lite  : 512px image/12 steps, 5s music, short low-res video    — fast sanity
#   heavy : 1280x720 image/30 steps, 120s music, long hi-res video — real-load test
#
# Outputs + log:  /tmp/agh-test/   (smoke.log = clean summary, with per-test timing)
set -uo pipefail

OUT=/tmp/agh-test
LOG="${OUT}/smoke.log"
mkdir -p "${OUT}"
: > "${LOG}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# log line goes to console AND clean log file
log() { echo -e "$*"; echo -e "$(echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g')" >> "${LOG}"; }

# ── Paths + pod ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
[[ -f /etc/profile.d/agh-paths.sh ]] && source /etc/profile.d/agh-paths.sh
if [[ -z "${AGH_MODELS:-}" ]]; then
  for c in /ephemeral /data /mnt/data; do mountpoint -q "$c" 2>/dev/null && { AGH_MODELS="$c/models"; break; }; done
  AGH_MODELS="${AGH_MODELS:-/opt/models}"
fi
MODELS_DIR="${AGH_MODELS}"
POD_PID=$(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | head -1)
[[ -n "$POD_PID" ]] || { echo "Pod not running — run setup_creative_suite.sh first."; exit 1; }
inpod() { nsenter -t "$POD_PID" -m -- bash -c "$1"; }

# ── Mode (size/length profile) ────────────────────────────────────────────────
MODE=lite
if [[ "${1:-}" == "lite" || "${1:-}" == "heavy" ]]; then MODE="$1"; shift; fi

if [[ "$MODE" == "heavy" ]]; then
  IMG_W=1280; IMG_H=720; IMG_STEPS=30
  MUSIC_DUR=120                                  # 2-minute track
  WAN_STEPS=40;  WAN_FRAMES=161; WAN_SIZE="1280*720"   # ~10s @16fps, hi-res
  HUN_FRAMES=129; HUN_W=960; HUN_H=544; HUN_STEPS=30   # ~10s, hi-res
  LTX_FRAMES=121; LTX_STEPS=30                          # LTX-Video (Bundle 3)
  COG_FRAMES=49;  COG_STEPS=50                          # CogVideoX-5B (Bundle 3, 49 frames fixed)
else
  IMG_W=512;  IMG_H=512;  IMG_STEPS=12
  MUSIC_DUR=5
  WAN_STEPS=10;  WAN_FRAMES=81;  WAN_SIZE="1280*720"
  HUN_FRAMES=25;  HUN_W=512; HUN_H=320; HUN_STEPS=15
  LTX_FRAMES=49;  LTX_STEPS=20
  COG_FRAMES=49;  COG_STEPS=20
fi

# Shared video prompt — same text for Wan2.1 and HunyuanVideo so the two clips are
# directly comparable.
SMOKE_PROMPT="A futuristic AI creative studio, holographic screens displaying glowing artwork, blue and purple particles drifting through the air, slow cinematic camera push forward, photorealistic, smooth motion, 4K"

# ── Which tests ───────────────────────────────────────────────────────────────
CORE=(image upscale music voice)                                   # always-available
ALL=(image upscale music voice wan21 hunyuan)                      # Bundle 1/2 tools
B3=(image upscale music voice wan21 hunyuan ltx cogvideo a1111 wan22 mochi)    # + Bundle 3-only tools
if [[ $# -eq 0 ]]; then
  TESTS=("${CORE[@]}")
elif [[ "${1:-}" == "all" ]]; then
  TESTS=("${ALL[@]}")
elif [[ "${1:-}" == "b3" || "${1:-}" == "all3" ]]; then
  TESTS=("${B3[@]}")
else
  TESTS=("$@")
fi

# Test fns return: 0 = PASS, 2 = SKIP (tool not installed in this bundle), other = FAIL.
declare -A RESULT TIMING
run_test() {
  local name="$1" fn="$2" start end rc
  log "${CYAN}▶ ${name}${NC} — running..."
  start=$(date +%s)
  "$fn"; rc=$?
  end=$(date +%s); TIMING[$name]=$(( end - start ))
  case "$rc" in
    0) RESULT[$name]="PASS"; log "  ${GREEN}✓ ${name} PASS${NC} (${TIMING[$name]}s)" ;;
    2) RESULT[$name]="SKIP"; log "  ${YELLOW}○ ${name} SKIP${NC} — not installed in this bundle" ;;
    *) RESULT[$name]="FAIL"; log "  ${RED}✗ ${name} FAIL${NC} (${TIMING[$name]}s) — see ${OUT}/${name}.err" ;;
  esac
}

# ── Test functions (return 0 = pass) ──────────────────────────────────────────
t_image() {
  local ckpt pid f
  ckpt=$(ls "${MODELS_DIR}"/comfyui/checkpoints/*.safetensors 2>/dev/null | head -1 | xargs -n1 basename)
  [[ -z "$ckpt" ]] && { echo "no checkpoint in ${MODELS_DIR}/comfyui/checkpoints" > "${OUT}/image.err"; return 1; }
  # Random seed each run: a fixed seed makes ComfyUI dedupe identical prompts and
  # return a cached result in 0.00s with no new output under this prompt_id (KeyError '7').
  local SEED=$(( (RANDOM<<15) ^ RANDOM ))
  log "    checkpoint: ${ckpt}  size: ${IMG_W}x${IMG_H}  steps: ${IMG_STEPS}  seed: ${SEED}"
  pid=$(curl -s -X POST http://127.0.0.1:8188/prompt -H "Content-Type: application/json" \
    -d "{\"prompt\":{\"1\":{\"class_type\":\"CheckpointLoaderSimple\",\"inputs\":{\"ckpt_name\":\"${ckpt}\"}},\"2\":{\"class_type\":\"CLIPTextEncode\",\"inputs\":{\"text\":\"a glowing blue robot, simple\",\"clip\":[\"1\",1]}},\"3\":{\"class_type\":\"CLIPTextEncode\",\"inputs\":{\"text\":\"blurry\",\"clip\":[\"1\",1]}},\"4\":{\"class_type\":\"EmptyLatentImage\",\"inputs\":{\"width\":${IMG_W},\"height\":${IMG_H},\"batch_size\":1}},\"5\":{\"class_type\":\"KSampler\",\"inputs\":{\"model\":[\"1\",0],\"positive\":[\"2\",0],\"negative\":[\"3\",0],\"latent_image\":[\"4\",0],\"seed\":${SEED},\"steps\":${IMG_STEPS},\"cfg\":7,\"sampler_name\":\"euler\",\"scheduler\":\"normal\",\"denoise\":1}},\"6\":{\"class_type\":\"VAEDecode\",\"inputs\":{\"samples\":[\"5\",0],\"vae\":[\"1\",2]}},\"7\":{\"class_type\":\"SaveImage\",\"inputs\":{\"images\":[\"6\",0],\"filename_prefix\":\"smoketest\"}}}}" \
    2>>"${OUT}/image.err" | python3 -c "import sys,json;print(json.load(sys.stdin).get('prompt_id',''))" 2>>"${OUT}/image.err")
  [[ -z "$pid" ]] && { echo "ComfyUI rejected prompt (is it running on :8188?)" >> "${OUT}/image.err"; return 1; }
  for _ in $(seq 1 36); do
    sleep 5
    [[ "$(curl -s http://127.0.0.1:8188/history/$pid | python3 -c "import sys,json;print('done' if json.load(sys.stdin) else '')" 2>/dev/null)" == "done" ]] && break
  done
  f=$(curl -s http://127.0.0.1:8188/history/$pid | python3 -c "import sys,json;d=json.load(sys.stdin);print(list(d.values())[0]['outputs']['7']['images'][0]['filename'])" 2>>"${OUT}/image.err")
  [[ -z "$f" ]] && { echo "no output image in history" >> "${OUT}/image.err"; return 1; }
  curl -s "http://127.0.0.1:8188/view?filename=$f&type=output" -o "${OUT}/img.png" 2>>"${OUT}/image.err"
  [[ -s "${OUT}/img.png" ]] && { log "    -> ${OUT}/img.png"; return 0; } || return 1
}

t_upscale() {
  [[ -s "${OUT}/img.png" ]] || { echo "no ${OUT}/img.png — run image test first" > "${OUT}/upscale.err"; return 1; }
  inpod "
source /opt/enhancement-env/bin/activate
python - <<'PY' 2>>${OUT}/upscale.err
import sys, types, torchvision.transforms.functional as _F
if 'torchvision.transforms.functional_tensor' not in sys.modules:
    m=types.ModuleType('torchvision.transforms.functional_tensor'); m.rgb_to_grayscale=_F.rgb_to_grayscale
    sys.modules['torchvision.transforms.functional_tensor']=m
import cv2
from realesrgan import RealESRGANer
from basicsr.archs.rrdbnet_arch import RRDBNet
mdl=RRDBNet(num_in_ch=3,num_out_ch=3,num_feat=64,num_block=23,num_grow_ch=32,scale=4)
up=RealESRGANer(scale=4, model_path='${MODELS_DIR}/realesrgan/RealESRGAN_x4plus.pth', model=mdl, half=True)
img=cv2.imread('${OUT}/img.png')
out,_=up.enhance(img, outscale=2)
cv2.imwrite('${OUT}/img_2x.png', out)
print('shape', out.shape)
PY
"
  [[ -s "${OUT}/img_2x.png" ]] && { log "    -> ${OUT}/img_2x.png"; return 0; } || return 1
}

t_music() {
  inpod "
source /opt/audio-env/bin/activate
python - <<'PY' 2>>${OUT}/music.err
from audiocraft.models import MusicGen
import torchaudio
m=MusicGen.get_pretrained('melody'); m.set_generation_params(duration=${MUSIC_DUR})
a=m.generate(['short upbeat electronic jingle'])[0].cpu()
torchaudio.save('${OUT}/music.wav', a, 32000)
print('ok')
PY
"
  [[ -s "${OUT}/music.wav" ]] && { log "    -> ${OUT}/music.wav"; return 0; } || return 1
}

t_voice() {
  [[ -d /opt/voice-env ]] || { echo "Bark (/opt/voice-env) not installed" > "${OUT}/voice.err"; return 2; }
  inpod "
source /opt/voice-env/bin/activate
python - <<'PY' 2>>${OUT}/voice.err
from bark import SAMPLE_RATE, generate_audio, preload_models
from scipy.io.wavfile import write
import numpy as np
preload_models()
a=generate_audio('Hello from A G H Creative Suite.')
write('${OUT}/voice.wav', SAMPLE_RATE, (a*32767).astype(np.int16))
print('ok')
PY
"
  [[ -s "${OUT}/voice.wav" ]] && { log "    -> ${OUT}/voice.wav"; return 0; } || return 1
}

t_wan21() {
  [[ -d /opt/Wan2.1 ]] || { echo "Wan2.1 (/opt/Wan2.1) not installed" > "${OUT}/wan21.err"; return 2; }
  local vram; vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
  if [[ "${vram:-0}" -lt 75000 ]]; then
    echo "GPU has ${vram}MB (<75GB) — Wan2.1 14B needs ~73GB, skipping" > "${OUT}/wan21.err"; return 2
  fi
  log "    (heavy — ~73GB VRAM; GPU must be free)  steps:${WAN_STEPS} frames:${WAN_FRAMES} size:${WAN_SIZE}"
  inpod "
source /opt/wan21-env/bin/activate
cd /opt/Wan2.1
python generate.py --task t2v-14B --size ${WAN_SIZE} \
  --ckpt_dir ${MODELS_DIR}/wan21 \
  --frame_num ${WAN_FRAMES} \
  --sample_steps ${WAN_STEPS} --sample_guide_scale 6.0 \
  --prompt '${SMOKE_PROMPT}' \
  --save_file ${OUT}/wan.mp4 2>>${OUT}/wan21.err
"
  [[ -s "${OUT}/wan.mp4" ]] && { log "    -> ${OUT}/wan.mp4"; return 0; } || return 1
}

t_hunyuan() {
  [[ -d /opt/agh-video-env ]] || { echo "AGH Video Studio (/opt/agh-video-env) not installed" > "${OUT}/hunyuan.err"; return 2; }
  log "    (heavy — downloads model on first run, slow)  frames:${HUN_FRAMES} size:${HUN_W}x${HUN_H} steps:${HUN_STEPS}"
  inpod "
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
v=pipe(prompt='${SMOKE_PROMPT}', num_frames=${HUN_FRAMES}, height=${HUN_H}, width=${HUN_W}, num_inference_steps=${HUN_STEPS}).frames[0]
export_to_video(v, '${OUT}/hunyuan.mp4', fps=12)
print('ok')
PY
"
  [[ -s "${OUT}/hunyuan.mp4" ]] && { log "    -> ${OUT}/hunyuan.mp4"; return 0; } || return 1
}

t_ltx() {
  [[ -d /opt/agh-video-env ]] || { echo "AGH Video Studio (/opt/agh-video-env) not installed — Bundle 3 only" > "${OUT}/ltx.err"; return 2; }
  log "    (LTX-Video, fast)  frames:${LTX_FRAMES} size:768x512 steps:${LTX_STEPS}"
  inpod "
source /opt/agh-video-env/bin/activate
export HF_HOME=${MODELS_DIR}/hf-cache
python - <<'PY' 2>>${OUT}/ltx.err
import torch
from diffusers import LTXPipeline
from diffusers.utils import export_to_video
pipe=LTXPipeline.from_pretrained('Lightricks/LTX-Video', torch_dtype=torch.bfloat16)
pipe.enable_model_cpu_offload()
v=pipe(prompt='${SMOKE_PROMPT}', width=768, height=512, num_frames=${LTX_FRAMES}, num_inference_steps=${LTX_STEPS}).frames[0]
export_to_video(v, '${OUT}/ltx.mp4', fps=24)
print('ok')
PY
"
  [[ -s "${OUT}/ltx.mp4" ]] && { log "    -> ${OUT}/ltx.mp4"; return 0; } || return 1
}

t_cogvideo() {
  [[ -d /opt/agh-video-env ]] || { echo "AGH Video Studio (/opt/agh-video-env) not installed — Bundle 3 only" > "${OUT}/cogvideo.err"; return 2; }
  log "    (CogVideoX-5B, downloads model on first run)  frames:${COG_FRAMES} steps:${COG_STEPS}"
  inpod "
source /opt/agh-video-env/bin/activate
export HF_HOME=${MODELS_DIR}/hf-cache
python - <<'PY' 2>>${OUT}/cogvideo.err
import torch
from diffusers import CogVideoXPipeline
from diffusers.utils import export_to_video
pipe=CogVideoXPipeline.from_pretrained('THUDM/CogVideoX-5b', torch_dtype=torch.bfloat16)
pipe.enable_model_cpu_offload(); pipe.vae.enable_tiling()
v=pipe(prompt='${SMOKE_PROMPT}', num_frames=${COG_FRAMES}, guidance_scale=6.0, num_inference_steps=${COG_STEPS}).frames[0]
export_to_video(v, '${OUT}/cogvideo.mp4', fps=8)
print('ok')
PY
"
  [[ -s "${OUT}/cogvideo.mp4" ]] && { log "    -> ${OUT}/cogvideo.mp4"; return 0; } || return 1
}

t_wan22() {
  [[ -d /opt/Wan2.2 ]] || { echo "Wan2.2 (/opt/Wan2.2) not installed — 80GB+ GPU only" > "${OUT}/wan22.err"; return 2; }
  local vram; vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
  local task="ti2v-5B"; [[ "${vram:-0}" -ge 75000 ]] && task="t2v-A14B"
  log "    (Wan2.2 ${task})  steps:${WAN_STEPS} frames:${WAN_FRAMES} size:${WAN_SIZE}"
  inpod "
source /opt/wan22-env/bin/activate
cd /opt/Wan2.2
python generate.py --task ${task} --size ${WAN_SIZE} \
  --ckpt_dir ${MODELS_DIR}/wan22 \
  --frame_num ${WAN_FRAMES} \
  --sample_steps ${WAN_STEPS} --sample_guide_scale 6.0 \
  --prompt '${SMOKE_PROMPT}' \
  --save_file ${OUT}/wan22.mp4 2>>${OUT}/wan22.err
"
  [[ -s "${OUT}/wan22.mp4" ]] && { log "    -> ${OUT}/wan22.mp4"; return 0; } || return 1
}

t_mochi() {
  [[ -d /opt/agh-video-env ]] || { echo "AGH Video Studio (/opt/agh-video-env) not installed — Bundle 3 only" > "${OUT}/mochi.err"; return 2; }
  local vram; vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
  if [[ "${vram:-0}" -lt 42000 ]]; then
    echo "GPU has ${vram}MB (<42GB) — Mochi-1 needs ~42GB+, skipping" > "${OUT}/mochi.err"; return 2
  fi
  log "    (Mochi-1, downloads model on first run)  frames:${HUN_FRAMES} steps:${HUN_STEPS}"
  inpod "
source /opt/agh-video-env/bin/activate
export HF_HOME=${MODELS_DIR}/hf-cache
python - <<'PY' 2>>${OUT}/mochi.err
import torch
from diffusers import MochiPipeline
from diffusers.utils import export_to_video
pipe=MochiPipeline.from_pretrained('genmo/mochi-1-preview', torch_dtype=torch.bfloat16)
pipe.enable_model_cpu_offload(); pipe.vae.enable_tiling()
v=pipe(prompt='${SMOKE_PROMPT}', height=480, width=848, num_frames=${HUN_FRAMES}, num_inference_steps=${HUN_STEPS}).frames[0]
export_to_video(v, '${OUT}/mochi.mp4', fps=15)
print('ok')
PY
"
  [[ -s "${OUT}/mochi.mp4" ]] && { log "    -> ${OUT}/mochi.mp4"; return 0; } || return 1
}

t_a1111() {
  [[ -d /opt/stable-diffusion-webui ]] || { echo "A1111 (/opt/stable-diffusion-webui) not installed — Bundle 3 only" > "${OUT}/a1111.err"; return 2; }
  # Needs the API enabled (setup launches launch.py with --api).
  if ! curl -s --connect-timeout 3 "http://127.0.0.1:7860/sdapi/v1/sd-models" >/dev/null 2>&1; then
    echo "A1111 API not reachable on :7860 (is it still starting, or launched without --api?)" > "${OUT}/a1111.err"; return 1
  fi
  log "    (A1111 REST API)  size:${IMG_W}x${IMG_H} steps:${IMG_STEPS}"
  local SEED=$(( (RANDOM<<15) ^ RANDOM ))
  curl -s -X POST "http://127.0.0.1:7860/sdapi/v1/txt2img" -H "Content-Type: application/json" \
    -d "{\"prompt\":\"a glowing blue robot, simple\",\"negative_prompt\":\"blurry\",\"steps\":${IMG_STEPS},\"width\":${IMG_W},\"height\":${IMG_H},\"seed\":${SEED},\"cfg_scale\":7}" \
    2>>"${OUT}/a1111.err" \
    | python3 -c "import sys,json,base64;d=json.load(sys.stdin);open('${OUT}/a1111.png','wb').write(base64.b64decode(d['images'][0]))" 2>>"${OUT}/a1111.err"
  [[ -s "${OUT}/a1111.png" ]] && { log "    -> ${OUT}/a1111.png"; return 0; } || return 1
}

# ── Run ───────────────────────────────────────────────────────────────────────
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"
log "${BOLD}  AGH Creative Suite smoke test${NC}"
SCRIPT_START=$(date +%s)
log "  Started:    $(date '+%Y-%m-%d %H:%M:%S')"
log "  Mode:       ${MODE}  (image ${IMG_W}x${IMG_H}/${IMG_STEPS}st · music ${MUSIC_DUR}s · wan ${WAN_FRAMES}f · hunyuan ${HUN_FRAMES}f · ltx ${LTX_FRAMES}f · cog ${COG_FRAMES}f)"
log "  Models dir: ${MODELS_DIR}"
log "  Tests:      ${TESTS[*]}"
log "  Outputs:    ${OUT}/"
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"

for t in "${TESTS[@]}"; do
  case "$t" in
    image)   run_test image   t_image   ;;
    upscale) run_test upscale t_upscale ;;
    music)   run_test music   t_music   ;;
    voice)   run_test voice   t_voice   ;;
    wan21)    run_test wan21    t_wan21    ;;
    hunyuan)  run_test hunyuan  t_hunyuan  ;;
    ltx)      run_test ltx      t_ltx      ;;
    cogvideo) run_test cogvideo t_cogvideo ;;
    a1111)    run_test a1111    t_a1111    ;;
    wan22)    run_test wan22    t_wan22    ;;
    mochi)    run_test mochi    t_mochi    ;;
    *) log "${YELLOW}skip unknown test: ${t}${NC}" ;;
  esac
done

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "${BOLD}──────────────── SUMMARY ────────────────${NC}"
fails=0; skips=0
for t in "${TESTS[@]}"; do
  [[ -n "${RESULT[$t]:-}" ]] || continue
  case "${RESULT[$t]}" in
    PASS) log "  ${GREEN}✓${NC} ${t}  (${TIMING[$t]}s)" ;;
    SKIP) log "  ${YELLOW}○${NC} ${t}  (skipped — not in this bundle)"; skips=$((skips+1)) ;;
    *)    log "  ${RED}✗${NC} ${t}  (${TIMING[$t]}s)"; fails=$((fails+1)) ;;
  esac
done
log "${BOLD}─────────────────────────────────────────${NC}"
TOTAL=$(( $(date +%s) - SCRIPT_START ))
log "  Total time: ${TOTAL}s ($(( TOTAL / 60 ))m $(( TOTAL % 60 ))s)   Mode: ${MODE}   Skipped: ${skips}"
log "  Finished:   $(date '+%H:%M:%S')   Log: ${LOG}"
if [[ "$fails" -eq 0 ]]; then
  log "  ${GREEN}${BOLD}ALL PASS${NC} — every installed tool works. Ready to run the promo demo."
  exit 0
else
  log "  ${RED}${BOLD}${fails} FAILED${NC} — check ${OUT}/<name>.err before running the demo."
  exit 1
fi
