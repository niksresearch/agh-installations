#!/usr/bin/env bash
# AGH Creative Suite — Promo Video Generator (Director's Cut, Bundle 2 "Creator")
#
# Sibling of demo_creative_suite.sh (which targets Bundle 1 "Starter").
# This version showcases the Bundle 2 upgrades end-to-end:
#   • Real AGH brand assets fetched from aghcloud.ai (logo + banner)
#   • FLUX images (ComfyUI) with automatic SDXL fallback
#   • Real-ESRGAN x4 upscale → crisp frames
#   • Two AI video engines: Wan2.1 + HunyuanVideo (AGH Video Studio diffusers)
#   • Bark TTS spoken voiceover narration
#   • MusicGen background score
#   • FFmpeg assembly: voiceover + ducked music, real-logo watermark, branded cards
#
# Run in background:
#   sudo nohup bash demo_creative_suite_v2.sh > /ephemeral/demo_v2.log 2>&1 &
#   tail -f /ephemeral/demo_v2.log
#
# Or foreground:
#   sudo bash demo_creative_suite_v2.sh
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

STEP_START=0
SERVER_IP_CACHE=""

# ulog: write to user log (FD 3) AND debug log (stdout, already redirected)
ulog() { echo "$*" >&3; echo "$*"; }

info()    { ulog "[$(date '+%H:%M:%S')] •  $*"; }
success() { ulog "[$(date '+%H:%M:%S')] ✓  $*"; }
warn()    { ulog "[$(date '+%H:%M:%S')] ⚠  $*"; }
cmd()     { ulog "[$(date '+%H:%M:%S')]    \$ $*"; }

show_output() {
  local label="$1"; shift
  local files=("$@")
  [[ -z "${SERVER_IP_CACHE}" ]] && \
    SERVER_IP_CACHE=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
  local key_arg=""
  for k in ~/.ssh/id_rsa ~/.ssh/id_ed25519 /root/.ssh/id_rsa /root/.ssh/id_ed25519; do
    [[ -f "$k" ]] && key_arg="-i ${k} " && break
  done
  ulog "[$(date '+%H:%M:%S')] 📁 ${label} — ready to download:"
  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then
      ulog "[$(date '+%H:%M:%S')]    ${f}  ($(du -sh $f 2>/dev/null | cut -f1))"
      ulog "[$(date '+%H:%M:%S')]    scp ${key_arg}shadeform@${SERVER_IP_CACHE}:${f} ~/Desktop/"
    elif [[ -d "$f" ]]; then
      ulog "[$(date '+%H:%M:%S')]    ${f}/"
      ulog "[$(date '+%H:%M:%S')]    scp ${key_arg}-r shadeform@${SERVER_IP_CACHE}:${f}/ ~/Desktop/$(basename $f)/"
    fi
  done
}

step() {
  local now
  now=$(date +%s)
  if [[ "$STEP_START" -gt 0 ]]; then
    local elapsed=$(( now - STEP_START ))
    ulog "[$(date '+%H:%M:%S')]    (took ${elapsed}s)"
  fi
  STEP_START=$now
  ulog ""
  ulog "[$(date '+%H:%M:%S')] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  ulog "[$(date '+%H:%M:%S')] $*"
  ulog "[$(date '+%H:%M:%S')] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

[[ $EUID -eq 0 ]] || { echo -e "${RED}[ERROR]${NC} Run as root: sudo bash $0"; exit 1; }

# ── Auto-detect paths ─────────────────────────────────────────────────────────
[[ -f /etc/profile.d/agh-paths.sh ]] && source /etc/profile.d/agh-paths.sh

if [[ -z "${AGH_DATA:-}" ]]; then
  for candidate in /ephemeral /data /mnt/data; do
    if mountpoint -q "${candidate}" 2>/dev/null; then
      AGH_DATA="${candidate}"
      AGH_MODELS="${candidate}/models"
      break
    fi
  done
  AGH_DATA="${AGH_DATA:-/opt}"
  AGH_MODELS="${AGH_MODELS:-/opt/models}"
fi

DATA_DIR="${AGH_DATA}"
MODELS_DIR="${AGH_MODELS}"
export TMPDIR="${TMPDIR:-${DATA_DIR}/tmp}"

OUTPUT_DIR="${DATA_DIR}/agh-promo-v2"
BRAND_DIR="${OUTPUT_DIR}/brand"
LOG_FILE="${OUTPUT_DIR}/demo.log"
DEBUG_LOG="${OUTPUT_DIR}/demo-debug.log"
mkdir -p "${OUTPUT_DIR}/images" "${OUTPUT_DIR}/images_4k" "${OUTPUT_DIR}/videos" "${BRAND_DIR}" "${DATA_DIR}/tmp"

# Re-exec into background if not already logging
if [[ "${DEMO_LOGGING:-0}" != "1" ]]; then
  export DEMO_LOGGING=1
  echo ""
  echo "  AGH Creative Suite — Director's Cut (Bundle 2) starting in background"
  echo ""
  echo "  Clean progress:  tail -f ${LOG_FILE}"
  echo "  Full debug log:  tail -f ${DEBUG_LOG}"
  echo ""
  exec sudo DEMO_LOGGING=1 nohup bash "$0" &
  echo "  PID: $!"
  exit 0
fi

# Two-stream logging:
#   FD 3        → user log  (clean: steps, status, downloads)
#   stdout+err  → debug log (all command noise: ffmpeg, blender, python)
exec 3>>"${LOG_FILE}"
exec >>"${DEBUG_LOG}" 2>&1

POD_PID=$(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | head -1)
[[ -n "$POD_PID" ]] || { echo -e "${RED}[ERROR]${NC} Pod not running. Run setup_creative_suite.sh first."; exit 1; }

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "GPU")

# ── Detect installed Bundle 2 tools ───────────────────────────────────────────
HAS_WAN21=false;    [[ -d /opt/Wan2.1 && -d "${MODELS_DIR}/wan21" ]] && HAS_WAN21=true
HAS_HUNYUAN=false;  [[ -d /opt/agh-video-env ]] && HAS_HUNYUAN=true
HAS_BARK=false;     nsenter -t "${POD_PID}" -m -- bash -c "source /opt/voice-env/bin/activate 2>/dev/null && python -c 'import bark' 2>/dev/null" && HAS_BARK=true || true
HAS_MUSICGEN=false; nsenter -t "${POD_PID}" -m -- bash -c "source /opt/audio-env/bin/activate 2>/dev/null && python -c 'import audiocraft' 2>/dev/null" && HAS_MUSICGEN=true || true
HAS_ESRGAN=false;   [[ -f "${MODELS_DIR}/realesrgan/RealESRGAN_x4plus.pth" && -d /opt/enhancement-env ]] && HAS_ESRGAN=true

# ── Pick the best available image model (FLUX → SDXL → SD1.5) ─────────────────
FLUX_UNET=""
for f in flux1-schnell.safetensors flux1-dev.safetensors; do
  [[ -f "${MODELS_DIR}/comfyui/unet/${f}" ]] && FLUX_UNET="${f}" && break
done
if [[ -n "${FLUX_UNET}" ]]; then
  IMG_MODE="flux"
elif [[ -f "${MODELS_DIR}/comfyui/checkpoints/sd_xl_base_1.0.safetensors" ]]; then
  IMG_MODE="sdxl"
elif [[ -f "${MODELS_DIR}/comfyui/checkpoints/v1-5-pruned-emaonly.safetensors" ]]; then
  IMG_MODE="sd15"
else
  IMG_MODE="none"
fi

ulog "════════════════════════════════════════════════════════════════"
ulog "  AGH Creative Suite — Director's Cut (Bundle 2 'Creator')"
ulog "  Made using the suite it promotes — premium pipeline"
ulog "════════════════════════════════════════════════════════════════"
ulog ""
ulog "  Every step below runs automatically — no human input."
ulog "  Real AGH branding, FLUX images, 4K upscale, two video"
ulog "  engines, a spoken voiceover and an original score — end to end."
ulog ""
ulog "  GPU:      ${GPU_NAME}"
ulog "  Started:  $(date '+%Y-%m-%d %H:%M:%S')"
ulog "  Outputs:  ${OUTPUT_DIR}/"
ulog ""
ulog "  Tools detected:"
ulog "    Image model:      ${IMG_MODE}"
ulog "    ESRGAN upscale:   ${HAS_ESRGAN}"
ulog "    Wan2.1 (video):   ${HAS_WAN21}"
ulog "    HunyuanVideo:     ${HAS_HUNYUAN}"
ulog "    Bark voiceover:   ${HAS_BARK}"
ulog "    MusicGen:         ${HAS_MUSICGEN}"
ulog "════════════════════════════════════════════════════════════════"
ulog ""

FONT_BOLD="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

# ── Helper: title/section card via FFmpeg ─────────────────────────────────────
make_card() {
  local out="$1" dur="$2" title="$3" subtitle="$4" bg="${5:-0x000a1a}" fg="${6:-white}" accent="${7:-00ccff}"
  nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error \
  -f lavfi -i color=c=${bg}:size=1280x720:duration=${dur}:rate=24 \
  -vf \"drawtext=text='${title}':fontsize=54:fontcolor=${fg}:x=(w-text_w)/2:y=(h-text_h)/2-50:fontfile=${FONT_BOLD},drawtext=text='${subtitle}':fontsize=26:fontcolor=#${accent}:x=(w-text_w)/2:y=(h-text_h)/2+30:fontfile=${FONT_REG},drawtext=text='AGH':fontsize=24:fontcolor=white@0.8:x=w-tw-28:y=24:fontfile=${FONT_BOLD}\" \
  -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p '${out}'
" 2>/dev/null
}

# ── Step 0: Fetch real AGH brand assets from aghcloud.ai ──────────────────────
step "Step 0/7: Fetch real AGH brand assets (aghcloud.ai)"
HAS_BRAND=false
cmd "curl https://aghcloud.ai/agh-icon.png  +  /og-image.png  # official logo + banner"
info "Pulling the real AGH logo and banner straight from the production site."
curl -sL --max-time 30 "https://aghcloud.ai/agh-icon.png" -o "${BRAND_DIR}/agh-icon.png" 2>/dev/null || true
curl -sL --max-time 30 "https://aghcloud.ai/og-image.png" -o "${BRAND_DIR}/og-image.png" 2>/dev/null || true
# Validate both are real PNGs (file magic) and non-trivial in size
if [[ -s "${BRAND_DIR}/agh-icon.png" ]] && [[ -s "${BRAND_DIR}/og-image.png" ]] \
   && file "${BRAND_DIR}/agh-icon.png" | grep -qi "PNG image" \
   && file "${BRAND_DIR}/og-image.png" | grep -qi "PNG image"; then
  HAS_BRAND=true
  success "Brand assets downloaded — using the genuine AGH logo + banner."
  show_output "AGH Brand Assets" "${BRAND_DIR}"
else
  warn "Could not fetch brand assets — falling back to generated title cards."
fi

# ── Step 1: Branded banner intro ──────────────────────────────────────────────
step "Step 1/7: Branded intro (real banner + logo)"
if [[ "$HAS_BRAND" == "true" ]]; then
  info "Compositing the official banner with the AGH logo and tagline."
  nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error \
  -loop 1 -t 5 -i '${BRAND_DIR}/og-image.png' \
  -loop 1 -t 5 -i '${BRAND_DIR}/agh-icon.png' \
  -filter_complex \"
    [0:v]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,setsar=1,fps=24,format=yuv420p,fade=t=in:st=0:d=1,fade=t=out:st=4:d=1[bg];
    [1:v]scale=200:-1[lg];
    [bg][lg]overlay=(W-w)/2:90,drawtext=text='Creative Suite':fontsize=40:fontcolor=white:x=(w-text_w)/2:y=h-220:fontfile=${FONT_BOLD},drawtext=text='Your GPU. Your Canvas. No Limits.':fontsize=24:fontcolor=0x00ccff:x=(w-text_w)/2:y=h-160:fontfile=${FONT_REG}[v]
  \" \
  -map '[v]' -t 5 -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p '${OUTPUT_DIR}/s1_intro.mp4'
" && success "Branded intro done." || warn "Branded intro failed — using plain card."
fi
# Fallback / always-have title card
if [[ ! -f "${OUTPUT_DIR}/s1_intro.mp4" ]]; then
  make_card "${OUTPUT_DIR}/s1_intro.mp4" 5 \
    "AGH Creative Suite" "Your GPU. Your Canvas. No Limits." \
    "0x000a1a" "white" "00ccff"
  success "Title card done."
fi

# ── Step 2: AI brand images via ComfyUI (FLUX → SDXL → SD1.5) ─────────────────
step "Step 2/7: AI brand images (ComfyUI — ${IMG_MODE})"

COMFYUI_URL="http://127.0.0.1:8188"

# Emit the right ComfyUI graph JSON for the detected model. SaveImage is always
# node "7" so the history parser below is identical across models.
comfy_graph() {
  local name="$1" prompt="$2"
  case "$IMG_MODE" in
    flux)
      cat <<JSON
{"prompt":{
"10":{"class_type":"VAELoader","inputs":{"vae_name":"ae.safetensors"}},
"11":{"class_type":"DualCLIPLoader","inputs":{"clip_name1":"clip_l.safetensors","clip_name2":"t5xxl_fp8_e4m3fn.safetensors","type":"flux"}},
"12":{"class_type":"UNETLoader","inputs":{"unet_name":"${FLUX_UNET}","weight_dtype":"fp8_e4m3fn"}},
"6":{"class_type":"CLIPTextEncode","inputs":{"text":"${prompt}","clip":["11",0]}},
"60":{"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["11",0]}},
"5":{"class_type":"EmptyLatentImage","inputs":{"width":1280,"height":720,"batch_size":1}},
"13":{"class_type":"KSampler","inputs":{"model":["12",0],"positive":["6",0],"negative":["60",0],"latent_image":["5",0],"seed":42,"steps":4,"cfg":1.0,"sampler_name":"euler","scheduler":"simple","denoise":1}},
"8":{"class_type":"VAEDecode","inputs":{"samples":["13",0],"vae":["10",0]}},
"7":{"class_type":"SaveImage","inputs":{"images":["8",0],"filename_prefix":"${name}"}}
}}
JSON
      ;;
    sdxl)
      cat <<JSON
{"prompt":{
"1":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"sd_xl_base_1.0.safetensors"}},
"2":{"class_type":"CLIPTextEncode","inputs":{"text":"${prompt}","clip":["1",1]}},
"3":{"class_type":"CLIPTextEncode","inputs":{"text":"blurry, ugly, watermark, low quality","clip":["1",1]}},
"4":{"class_type":"EmptyLatentImage","inputs":{"width":1024,"height":1024,"batch_size":1}},
"5":{"class_type":"KSampler","inputs":{"model":["1",0],"positive":["2",0],"negative":["3",0],"latent_image":["4",0],"seed":42,"steps":30,"cfg":7.0,"sampler_name":"dpmpp_2m","scheduler":"karras","denoise":1}},
"6":{"class_type":"VAEDecode","inputs":{"samples":["5",0],"vae":["1",2]}},
"7":{"class_type":"SaveImage","inputs":{"images":["6",0],"filename_prefix":"${name}"}}
}}
JSON
      ;;
    *)
      cat <<JSON
{"prompt":{
"1":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"v1-5-pruned-emaonly.safetensors"}},
"2":{"class_type":"CLIPTextEncode","inputs":{"text":"${prompt}","clip":["1",1]}},
"3":{"class_type":"CLIPTextEncode","inputs":{"text":"blurry, ugly, watermark, low quality","clip":["1",1]}},
"4":{"class_type":"EmptyLatentImage","inputs":{"width":1280,"height":720,"batch_size":1}},
"5":{"class_type":"KSampler","inputs":{"model":["1",0],"positive":["2",0],"negative":["3",0],"latent_image":["4",0],"seed":42,"steps":25,"cfg":7.5,"sampler_name":"euler","scheduler":"normal","denoise":1}},
"6":{"class_type":"VAEDecode","inputs":{"samples":["5",0],"vae":["1",2]}},
"7":{"class_type":"SaveImage","inputs":{"images":["6",0],"filename_prefix":"${name}"}}
}}
JSON
      ;;
  esac
}

if [[ "$IMG_MODE" != "none" ]] && curl -s --connect-timeout 3 "${COMFYUI_URL}/system_stats" &>/dev/null; then
  cmd "curl -X POST ${COMFYUI_URL}/prompt  # ${IMG_MODE} image generation via ComfyUI API"
  info "This demonstrates: premium AI image generation — unlimited, no credits, no watermarks"
  [[ "$IMG_MODE" == "flux" ]] && info "Using FLUX — state-of-the-art open image model."

  PROMPTS=(
    "agh_workstation|A sleek futuristic AI creative workstation glowing with blue and purple light, multiple holographic screens showing AI-generated artwork, dark minimal setup, cinematic lighting, ultra detailed"
    "agh_creator|A confident African creative professional in front of multiple screens showing stunning AI-generated videos and images, golden hour light, inspired expression, cinematic aspirational"
    "agh_abstract_ai|Abstract visualization of artificial intelligence creativity, flowing neural networks forming beautiful art, electric blue and purple particles, deep space background, 8K"
    "agh_gpu_power|An H100 GPU chip glowing with neon blue light, futuristic close-up macro shot, cinematic dramatic lighting, chrome and silicon textures"
    "agh_continent|A glowing map of Africa rendered as a circuit board with light flowing across it, data centers lighting up, electric blue and cyan, futuristic, cinematic 8K"
    "agh_no_limits|A creative studio at night, screens glowing with AI-generated art, inspiring atmosphere, cinematic wide shot, photorealistic"
  )

  for entry in "${PROMPTS[@]}"; do
    name="${entry%%|*}"
    prompt="${entry##*|}"
    out_path="${OUTPUT_DIR}/images/${name}.png"
    [[ -f "$out_path" ]] && { info "Already exists: ${name}.png"; continue; }

    info "Generating: ${name}..."
    GRAPH=$(comfy_graph "${name}" "${prompt}")
    PROMPT_ID=$(curl -s -X POST "${COMFYUI_URL}/prompt" \
      -H "Content-Type: application/json" \
      -d "${GRAPH}" \
      2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt_id',''))" 2>/dev/null || echo "")

    if [[ -z "$PROMPT_ID" ]]; then
      warn "ComfyUI rejected prompt for ${name} — skipping"
      continue
    fi

    # Wait for completion (up to 4 min per image — FLUX/SDXL can be slower)
    for i in $(seq 1 48); do
      sleep 5
      STATUS=$(curl -s "${COMFYUI_URL}/history/${PROMPT_ID}" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print('done' if d else 'waiting')" 2>/dev/null || echo "waiting")
      [[ "$STATUS" == "done" ]] && break
    done

    GENERATED=$(curl -s "${COMFYUI_URL}/history/${PROMPT_ID}" 2>/dev/null | \
      python3 -c "
import sys,json
d=json.load(sys.stdin)
for k,v in d.items():
    imgs=v.get('outputs',{}).get('7',{}).get('images',[])
    if imgs: print(imgs[0]['filename']); break
" 2>/dev/null || echo "")

    if [[ -n "$GENERATED" ]]; then
      curl -s "${COMFYUI_URL}/view?filename=${GENERATED}&type=output" -o "${out_path}" 2>/dev/null
      [[ -f "$out_path" ]] && success "Generated: ${name}.png" || warn "Download failed: ${name}"
    else
      warn "No output for ${name}"
    fi
  done
  show_output "AI Images (${IMG_MODE})" "${OUTPUT_DIR}/images"
else
  warn "ComfyUI not running or no image model present — skipping AI images."
  warn "Start ComfyUI (port 8188) or run setup_creative_suite.sh with Bundle 2."
fi

# ── Step 3: Real-ESRGAN x4 upscale → crisp frames ─────────────────────────────
step "Step 3/7: 4K upscale (Real-ESRGAN x4)"

SLIDE_SRC_DIR="${OUTPUT_DIR}/images"   # default: use originals for the slideshow
if [[ "$HAS_ESRGAN" == "true" ]] && ls "${OUTPUT_DIR}/images"/*.png &>/dev/null; then
  cmd "RealESRGANer(scale=4).enhance(img, outscale=2)  # upscale + denoise each frame"
  info "This demonstrates: AI super-resolution — turn every frame razor-sharp on the GPU"
  UPSCALED=0
  for img in "${OUTPUT_DIR}/images"/*.png; do
    base=$(basename "$img")
    nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/enhancement-env/bin/activate
python - << 'PYEOF'
import os, sys, types
import torch
# basicsr imports torchvision.transforms.functional_tensor which newer torchvision removed.
import torchvision.transforms.functional as _F
if 'torchvision.transforms.functional_tensor' not in sys.modules:
    _m = types.ModuleType('torchvision.transforms.functional_tensor')
    _m.rgb_to_grayscale = _F.rgb_to_grayscale
    sys.modules['torchvision.transforms.functional_tensor'] = _m
import cv2
from basicsr.archs.rrdbnet_arch import RRDBNet
from realesrgan import RealESRGANer
model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4)
up = RealESRGANer(scale=4, model_path='${MODELS_DIR}/realesrgan/RealESRGAN_x4plus.pth',
                  model=model, tile=512, tile_pad=10, pre_pad=0,
                  half=torch.cuda.is_available())
img = cv2.imread('${img}', cv2.IMREAD_COLOR)
out, _ = up.enhance(img, outscale=2)
cv2.imwrite('${OUTPUT_DIR}/images_4k/${base}', out)
print('UPSCALED ${base}')
PYEOF
" && { UPSCALED=$((UPSCALED+1)); info "Upscaled ${base}"; } || warn "Upscale failed: ${base} (will use original)"
  done
  if [[ "$UPSCALED" -gt 0 ]]; then
    SLIDE_SRC_DIR="${OUTPUT_DIR}/images_4k"
    success "Upscaled ${UPSCALED} frames to high resolution."
    show_output "Upscaled Frames" "${OUTPUT_DIR}/images_4k"
  else
    warn "No frames upscaled — slideshow will use originals."
  fi
else
  warn "Real-ESRGAN not installed or no images — skipping upscale."
fi

# Assemble image slideshow from the best available frames
if ls "${SLIDE_SRC_DIR}"/*.png &>/dev/null; then
  info "Assembling image slideshow (Ken Burns zoom)..."
  SLIDE_CONCAT="${OUTPUT_DIR}/slides_concat.txt"; > "${SLIDE_CONCAT}"
  n=0
  for img in "${SLIDE_SRC_DIR}"/*.png; do
    clip="${OUTPUT_DIR}/slide_${n}.mp4"
    nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error -loop 1 -t 3 -i '${img}' \
  -vf 'scale=1600:900:force_original_aspect_ratio=increase,crop=1600:900,zoompan=z=min(zoom+0.0015\,1.12):d=72:s=1280x720,setsar=1' \
  -c:v libx264 -preset fast -crf 20 -r 24 '${clip}'" 2>/dev/null \
    || nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error -loop 1 -t 3 -i '${img}' \
  -vf 'scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,setsar=1' \
  -c:v libx264 -preset fast -crf 20 -r 24 '${clip}'" 2>/dev/null
    echo "file '${clip}'" >> "${SLIDE_CONCAT}"
    n=$((n+1))
  done
  nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error -f concat -safe 0 -i '${SLIDE_CONCAT}' \
  -c:v libx264 -preset fast -crf 20 '${OUTPUT_DIR}/s2_images.mp4'"
  success "Image slideshow assembled (${n} images)."
fi

# ── Step 4: AI video — Wan2.1 + HunyuanVideo ──────────────────────────────────
step "Step 4/7: AI video (Wan2.1 + HunyuanVideo)"

# 4a — Wan2.1 (same proven engine as Bundle 1)
if [[ "$HAS_WAN21" == "true" ]]; then
  cmd "python generate.py --task t2v-14B --size 1280*720  # Wan2.1 clip: futuristic studio"
  info "This demonstrates: AI video generation — no 8-second limit, no watermarks"
  info "Commercial equivalent: RunwayML ~\$0.05/sec ≈ \$3 for this clip. Cost here: \$0."
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/wan21-env/bin/activate
cd /opt/Wan2.1
TMPDIR=${TMPDIR} python generate.py \
  --task t2v-14B \
  --size 1280*720 \
  --ckpt_dir ${MODELS_DIR}/wan21 \
  --sample_steps 50 \
  --sample_guide_scale 6.0 \
  --prompt 'A futuristic AI creative studio. Holographic screens display stunning AI-generated artwork being created in real-time. Glowing particle effects flow between screens. Camera slowly pushes forward. Deep blue and purple lighting. Cinematic, photorealistic, ultra smooth motion, 4K commercial quality.' \
  --save_file ${OUTPUT_DIR}/videos/wan21_studio.mp4
" && {
    nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error -i ${OUTPUT_DIR}/videos/wan21_studio.mp4 \
  -t 15 -c:v libx264 -preset fast -crf 20 ${OUTPUT_DIR}/s4_wan.mp4"
    success "Wan2.1 video done."
    show_output "AI Video — Wan2.1" "${OUTPUT_DIR}/s4_wan.mp4"
  } || warn "Wan2.1 generation failed."
else
  warn "Wan2.1 not installed — skipping Wan2.1 clip."
fi

# 4b — HunyuanVideo via AGH Video Studio diffusers venv (Bundle 2 upgrade)
if [[ "$HAS_HUNYUAN" == "true" ]]; then
  cmd "HunyuanVideoPipeline(...).__call__(prompt, num_frames=61)  # AGH Video Studio engine"
  info "This demonstrates: HunyuanVideo — a top open video model, richer motion than Wan2.1"
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/agh-video-env/bin/activate
export HF_HOME=${MODELS_DIR}/hf-cache
TMPDIR=${TMPDIR} python - << 'PYEOF'
import torch
from diffusers import HunyuanVideoPipeline, HunyuanVideoTransformer3DModel
from diffusers.utils import export_to_video
repo = 'hunyuanvideo-community/HunyuanVideo'
tr = HunyuanVideoTransformer3DModel.from_pretrained(repo, subfolder='transformer', torch_dtype=torch.bfloat16)
pipe = HunyuanVideoPipeline.from_pretrained(repo, transformer=tr, torch_dtype=torch.float16)
pipe.enable_model_cpu_offload()
try:
    pipe.vae.enable_tiling()
except Exception:
    pass
out = pipe(
    prompt='Cinematic shot gliding through a neon-lit AI art gallery, glowing abstract sculptures of light, deep blue and magenta, volumetric haze, smooth camera motion, photorealistic',
    height=320, width=512, num_frames=61, num_inference_steps=30,
).frames[0]
export_to_video(out, '${OUTPUT_DIR}/videos/hunyuan_gallery.mp4', fps=15)
print('HUNYUAN_DONE')
PYEOF
" && {
    nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error -i ${OUTPUT_DIR}/videos/hunyuan_gallery.mp4 \
  -vf 'scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1' \
  -c:v libx264 -preset fast -crf 20 ${OUTPUT_DIR}/s4b_hunyuan.mp4"
    success "HunyuanVideo clip done."
    show_output "AI Video — HunyuanVideo" "${OUTPUT_DIR}/s4b_hunyuan.mp4"
  } || warn "HunyuanVideo generation failed — continuing with Wan2.1 only."
else
  warn "AGH Video Studio (HunyuanVideo) not installed — skipping Hunyuan clip."
fi

# ── Step 5: Spoken voiceover via Bark TTS ─────────────────────────────────────
step "Step 5/7: Spoken voiceover (Bark TTS)"

if [[ "$HAS_BARK" == "true" ]]; then
  cmd "bark.generate_audio(line) for line in script  # narrated voiceover"
  info "This demonstrates: AI text-to-speech — a real spoken narration, no voice actor"
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/voice-env/bin/activate
export HF_HOME=${MODELS_DIR}/hf-cache
export SUNO_USE_SMALL_MODELS=0
TMPDIR=${TMPDIR} python - << 'PYEOF'
import numpy as np
from bark import SAMPLE_RATE, generate_audio, preload_models
preload_models()
lines = [
    'Introducing the A G H Creative Suite.',
    'Powered entirely by your own G P U.',
    'Generate stunning images with state of the art models.',
    'Create cinematic video. No time limits. No watermarks.',
    'All running on Africa\\'s own G P U hub.',
    'Your G P U. Your canvas. No limits.',
]
gap = np.zeros(int(0.4 * SAMPLE_RATE), dtype=np.float32)
parts = []
for ln in lines:
    a = generate_audio(ln).astype(np.float32)
    parts.append(a); parts.append(gap)
audio = np.concatenate(parts)
peak = float(np.max(np.abs(audio))) or 1.0
audio = (audio / peak * 0.95 * 32767).astype(np.int16)
from scipy.io.wavfile import write as wavwrite
wavwrite('${OUTPUT_DIR}/voiceover.wav', SAMPLE_RATE, audio)
print('Voiceover saved')
PYEOF
" && { success "Voiceover narration generated."; show_output "Voiceover" "${OUTPUT_DIR}/voiceover.wav"; } \
  || warn "Bark voiceover failed — final video will have no narration."
else
  warn "Bark not installed — skipping voiceover."
fi

# ── Step 6: Background music via MusicGen ─────────────────────────────────────
step "Step 6/7: Background music (MusicGen)"

if [[ "$HAS_MUSICGEN" == "true" ]]; then
  cmd "MusicGen.get_pretrained('melody').generate([...])  # original 75s score"
  info "This demonstrates: AI music — a custom track, no licensing fees, generated on demand"
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/audio-env/bin/activate
export HF_HOME=${MODELS_DIR}/hf-cache
TMPDIR=${TMPDIR} python - << 'PYEOF'
from audiocraft.models import MusicGen
import torchaudio
m = MusicGen.get_pretrained('melody')
m.set_generation_params(duration=75)
audio = m.generate([
    'Epic cinematic orchestral and electronic music for a premium tech product reveal. '
    'Starts minimal and mysterious, builds with intensity, climaxes around 30 seconds '
    'with full orchestra and modern synths, inspiring and futuristic.'
])[0].cpu()
torchaudio.save('${OUTPUT_DIR}/music.wav', audio, 32000)
print('Music saved')
PYEOF
" && { success "Background music generated."; show_output "Background Music" "${OUTPUT_DIR}/music.wav"; } \
  || warn "MusicGen failed — no music in final reel."
else
  warn "MusicGen not installed — skipping music."
fi

# ── Step 7: Section cards + final assembly ────────────────────────────────────
step "Step 7/7: Branding + Final Assembly"

# Section label cards (only if that segment exists)
[[ -f "${OUTPUT_DIR}/s2_images.mp4" ]] && \
  make_card "${OUTPUT_DIR}/card_images.mp4" 2.5 "AI Image Generation" "FLUX · 4K Upscaled · No Credits" "0x001a0a" "white" "00ff88"
[[ -f "${OUTPUT_DIR}/s4_wan.mp4" || -f "${OUTPUT_DIR}/s4b_hunyuan.mp4" ]] && \
  make_card "${OUTPUT_DIR}/card_video.mp4" 2.5 "AI Video Generation" "Wan2.1 + HunyuanVideo — No Limits" "0x1a0500" "white" "ff6600"

# Branded end card (with real logo if available)
if [[ "$HAS_BRAND" == "true" ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error \
  -f lavfi -i color=c=0x05060a:size=1280x720:duration=6:rate=24 \
  -loop 1 -t 6 -i '${BRAND_DIR}/agh-icon.png' \
  -filter_complex \"
    [1:v]scale=240:-1[lg];
    [0:v][lg]overlay=(W-w)/2:(H-h)/2-110,
    drawtext=text='CREATIVE SUITE':fontsize=30:fontcolor=white:x=(w-text_w)/2:y=h/2+40:fontfile=${FONT_REG},
    drawtext=text='This entire video was made using AGH Creative Suite':fontsize=20:fontcolor=0x00ccff:x=(w-text_w)/2:y=h/2+95:fontfile=${FONT_REG},
    drawtext=text='aghcloud.ai':fontsize=18:fontcolor=0x8b949e:x=(w-text_w)/2:y=h/2+135:fontfile=${FONT_REG}[v]
  \" \
  -map '[v]' -t 6 -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p ${OUTPUT_DIR}/card_end.mp4
" && success "Branded end card done." || warn "End card failed."
fi
if [[ ! -f "${OUTPUT_DIR}/card_end.mp4" ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error \
  -f lavfi -i color=c=0x05060a:size=1280x720:duration=6:rate=24 \
  -vf \"
    drawtext=text='AGH':fontsize=110:fontcolor=0x58a6ff:x=(w-text_w)/2:y=(h-text_h)/2-100:fontfile=${FONT_BOLD},
    drawtext=text='CREATIVE SUITE':fontsize=28:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2-10:fontfile=${FONT_REG},
    drawtext=text='This entire video was made using AGH Creative Suite':fontsize=20:fontcolor=0x00ccff:x=(w-text_w)/2:y=(h-text_h)/2+50:fontfile=${FONT_REG},
    drawtext=text='aghcloud.ai':fontsize=18:fontcolor=0x8b949e:x=(w-text_w)/2:y=(h-text_h)/2+90:fontfile=${FONT_REG}
  \" \
  -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p ${OUTPUT_DIR}/card_end.mp4
" && success "Branded end card done." || warn "End card failed."
fi

# ── Normalize every segment to uniform spec (.ts) so concat never fails ────────
info "Normalizing all segments to uniform format..."
TS_LIST="${OUTPUT_DIR}/ts_list.txt"; > "${TS_LIST}"
SEG_ORDER=(
  "s1_intro.mp4"
  "card_images.mp4" "s2_images.mp4"
  "card_video.mp4"  "s4_wan.mp4" "s4b_hunyuan.mp4"
  "card_end.mp4"
)
ts_idx=0
for seg in "${SEG_ORDER[@]}"; do
  src="${OUTPUT_DIR}/${seg}"
  [[ -f "$src" ]] || continue
  ts="${OUTPUT_DIR}/seg_${ts_idx}.ts"
  nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error -i '${src}' \
  -vf 'scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=24,format=yuv420p' \
  -c:v libx264 -preset fast -crf 20 -an \
  -bsf:v h264_mp4toannexb -f mpegts '${ts}'
" && { echo "file '${ts}'" >> "${TS_LIST}"; ts_idx=$((ts_idx+1)); } || warn "Normalize failed: ${seg}"
done

FINAL="${OUTPUT_DIR}/AGH_Creative_Suite_Promo_DirectorsCut.mp4"

if [[ "$ts_idx" -gt 0 ]]; then
  info "Stitching ${ts_idx} segments + logo watermark + voiceover + music into final video..."

  # Build the input + filter graph dynamically based on what audio/brand we have.
  # Inputs:  0 = concat video.  Then optionally logo, voiceover, music in that order.
  INPUTS=(-f concat -safe 0 -i "${TS_LIST}")
  next_idx=1
  LOGO_IDX=-1; VO_IDX=-1; MUS_IDX=-1
  if [[ "$HAS_BRAND" == "true" && -f "${BRAND_DIR}/agh-icon.png" ]]; then
    INPUTS+=(-i "${BRAND_DIR}/agh-icon.png"); LOGO_IDX=$next_idx; next_idx=$((next_idx+1))
  fi
  if [[ -f "${OUTPUT_DIR}/voiceover.wav" ]]; then
    INPUTS+=(-i "${OUTPUT_DIR}/voiceover.wav"); VO_IDX=$next_idx; next_idx=$((next_idx+1))
  fi
  if [[ -f "${OUTPUT_DIR}/music.wav" ]]; then
    INPUTS+=(-i "${OUTPUT_DIR}/music.wav"); MUS_IDX=$next_idx; next_idx=$((next_idx+1))
  fi

  # Video chain: real logo overlay if present, else a text watermark.
  if [[ "$LOGO_IDX" -ge 0 ]]; then
    VCHAIN="[${LOGO_IDX}:v]scale=120:-1[lg];[0:v][lg]overlay=W-w-24:20[v]"
  else
    VCHAIN="[0:v]drawtext=text='AGH':fontsize=30:fontcolor=white@0.85:x=w-tw-28:y=24:fontfile=${FONT_BOLD},drawtext=text='Creative Suite':fontsize=12:fontcolor=0x00ccff@0.85:x=w-tw-28:y=58:fontfile=${FONT_REG}[v]"
  fi

  # Audio chain: voiceover (padded to run under the whole video) + ducked music.
  ACHAIN=""; AMAP=""
  if [[ "$VO_IDX" -ge 0 && "$MUS_IDX" -ge 0 ]]; then
    ACHAIN=";[${VO_IDX}:a]aresample=44100,apad,volume=1.0[vo];[${MUS_IDX}:a]aresample=44100,volume=0.16[mus];[vo][mus]amix=inputs=2:duration=longest:dropout_transition=0[a]"
    AMAP="-map [a]"
  elif [[ "$VO_IDX" -ge 0 ]]; then
    ACHAIN=";[${VO_IDX}:a]aresample=44100,volume=1.0[a]"
    AMAP="-map [a]"
  elif [[ "$MUS_IDX" -ge 0 ]]; then
    ACHAIN=";[${MUS_IDX}:a]aresample=44100,volume=0.5[a]"
    AMAP="-map [a]"
  fi

  if [[ -n "$AMAP" ]]; then
    nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error \
  ${INPUTS[*]} \
  -filter_complex \"${VCHAIN}${ACHAIN}\" \
  -map '[v]' ${AMAP} \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  -c:a aac -b:a 192k -shortest \
  '${FINAL}'
" && { success "FINAL Director's Cut (with audio): ${FINAL}"; } || warn "Final assembly failed."
  else
    nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error \
  ${INPUTS[*]} \
  -filter_complex \"${VCHAIN}\" \
  -map '[v]' \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  '${FINAL}'
" && { success "FINAL Director's Cut (no audio): ${FINAL}"; } || warn "Final assembly failed."
  fi

  rm -f "${OUTPUT_DIR}"/seg_*.ts 2>/dev/null || true
else
  warn "No segments to assemble — aborting final."
fi

# Surface the final video prominently
if [[ -f "${FINAL}" ]]; then
  ulog ""
  ulog "  ★★★  FINAL DIRECTOR'S CUT READY  ★★★"
  show_output "FINAL PROMO VIDEO" "${FINAL}"
else
  warn "No final video produced — check ${DEBUG_LOG}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
TOTAL_TIME=$(( $(date +%s) - STEP_START ))

ulog ""
ulog "════════════════════════════════════════════════════════════════"
ulog "  AGH Promo — Director's Cut Complete!"
ulog "════════════════════════════════════════════════════════════════"
ulog ""
ulog "  Finished:  $(date '+%Y-%m-%d %H:%M:%S')"
ulog "  GPU used:  ${GPU_NAME}"
ulog ""
ulog "  WHAT JUST HAPPENED (automatically, zero human input):"
[[ "$HAS_BRAND" == "true" ]]              && ulog "  ✓ Real AGH logo + banner fetched  — aghcloud.ai"
[[ -f "${OUTPUT_DIR}/s2_images.mp4" ]]    && ulog "  ✓ AI brand images generated       — ComfyUI / ${IMG_MODE}"
[[ -d "${OUTPUT_DIR}/images_4k" ]] && ls "${OUTPUT_DIR}/images_4k"/*.png &>/dev/null \
                                          && ulog "  ✓ Frames upscaled to high-res     — Real-ESRGAN x4"
[[ -f "${OUTPUT_DIR}/s4_wan.mp4" ]]       && ulog "  ✓ AI video clip generated         — Wan2.1 14B"
[[ -f "${OUTPUT_DIR}/s4b_hunyuan.mp4" ]]  && ulog "  ✓ AI video clip generated         — HunyuanVideo"
[[ -f "${OUTPUT_DIR}/voiceover.wav" ]]    && ulog "  ✓ Spoken voiceover narrated       — Bark TTS"
[[ -f "${OUTPUT_DIR}/music.wav" ]]        && ulog "  ✓ Background music created        — MusicGen"
[[ -f "${FINAL}" ]]                       && ulog "  ✓ Final video assembled           — FFmpeg"
ulog ""
ulog "  Output:    ${FINAL}"
[[ -f "${FINAL}" ]] && ulog "  Size:      $(du -sh ${FINAL} | cut -f1)"
ulog ""

# ── Auto-detect server IP and build download commands ─────────────────────────
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
            curl -s --connect-timeout 5 api.ipify.org 2>/dev/null || \
            echo "YOUR_SERVER_IP")
SSH_KEY=""
for k in ~/.ssh/id_rsa ~/.ssh/id_ed25519 /root/.ssh/id_rsa /root/.ssh/id_ed25519; do
  [[ -f "$k" ]] && SSH_KEY="$k" && break
done
KEY_ARG=""
[[ -n "$SSH_KEY" ]] && KEY_ARG="-i ${SSH_KEY} "

ulog "  DOWNLOAD TO YOUR LAPTOP (run on your laptop):"
ulog ""
[[ -f "${FINAL}" ]] && ulog "  scp ${KEY_ARG}shadeform@${SERVER_IP}:${FINAL} ~/Desktop/"
ulog "  scp ${KEY_ARG}-r shadeform@${SERVER_IP}:${OUTPUT_DIR}/ ~/Desktop/agh-promo-v2/"
ulog ""
ulog "  This video was made entirely using AGH Creative Suite (Bundle 2)."
ulog "  You are watching the product."
ulog ""
