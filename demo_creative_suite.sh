#!/usr/bin/env bash
# AGH Creative Suite — Promo Video Generator
#
# Creates AGH's own promotional video using AGH Creative Suite.
# "We made this promo using the thing we're promoting."
#
# Segments:
#   1. Title card
#   2. AI brand images via Fooocus/diffusers (6 images → slideshow)
#   3. AGH logo 3D reveal via Blender
#   4. AI video via Wan2.1 (futuristic workspace)
#   5. Background music via MusicGen
#   6. Final assembly via FFmpeg
#
# Run in background:
#   sudo nohup bash demo_creative_suite.sh > /ephemeral/demo.log 2>&1 &
#   tail -f /ephemeral/demo.log
#
# Or foreground:
#   sudo bash demo_creative_suite.sh
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

# Fall back to largest available disk if agh-paths.sh not set
if [[ -z "${AGH_DATA:-}" ]]; then
  for candidate in /ephemeral /data /mnt/data; do
    if mountpoint -q "${candidate}" 2>/dev/null; then
      AGH_DATA="${candidate}"
      AGH_MODELS="${candidate}/models"
      break
    fi
  done
  # Last resort: root disk
  AGH_DATA="${AGH_DATA:-/opt}"
  AGH_MODELS="${AGH_MODELS:-/opt/models}"
fi

DATA_DIR="${AGH_DATA}"
MODELS_DIR="${AGH_MODELS}"
export TMPDIR="${TMPDIR:-${DATA_DIR}/tmp}"

OUTPUT_DIR="${DATA_DIR}/agh-promo"
LOG_FILE="${OUTPUT_DIR}/demo.log"
DEBUG_LOG="${OUTPUT_DIR}/demo-debug.log"
mkdir -p "${OUTPUT_DIR}/images" "${OUTPUT_DIR}/videos" "${DATA_DIR}/tmp"

# Re-exec into background if not already logging
if [[ "${DEMO_LOGGING:-0}" != "1" ]]; then
  export DEMO_LOGGING=1
  echo ""
  echo "  AGH Creative Suite — Demo starting in background"
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

# Detect installed tools
HAS_WAN21=false;    [[ -d /opt/Wan2.1 && -d "${MODELS_DIR}/wan21" ]] && HAS_WAN21=true
HAS_MUSICGEN=false; nsenter -t "${POD_PID}" -m -- bash -c "source /opt/audio-env/bin/activate 2>/dev/null && python -c 'import audiocraft' 2>/dev/null" && HAS_MUSICGEN=true || true
HAS_BLENDER=false;  nsenter -t "${POD_PID}" -m -- bash -c "command -v blender" &>/dev/null && HAS_BLENDER=true || true
HAS_DIFFUSERS=false  # Image generation via ComfyUI (port 8188) — not included in auto-demo

ulog "════════════════════════════════════════════════════════════════"
ulog "  AGH Creative Suite — Promo Video Generator"
ulog "  Made using the suite it promotes"
ulog "════════════════════════════════════════════════════════════════"
ulog ""
ulog "  Every step below runs automatically — no human input."
ulog "  This IS the product demonstrating itself: AI video, 3D"
ulog "  animation, music, and editing, end to end."
ulog ""
ulog "  GPU:      ${GPU_NAME}"
ulog "  Started:  $(date '+%Y-%m-%d %H:%M:%S')"
ulog "  Outputs:  ${OUTPUT_DIR}/"
ulog ""
ulog "  Tools detected:"
ulog "    Blender (3D):   ${HAS_BLENDER}"
ulog "    Wan2.1 (video): ${HAS_WAN21}"
ulog "    MusicGen:       ${HAS_MUSICGEN}"
ulog "════════════════════════════════════════════════════════════════"
ulog ""

# ── Helper: title/section card via FFmpeg ─────────────────────────────────────
make_card() {
  local out="$1" dur="$2" title="$3" subtitle="$4" bg="${5:-0x000a1a}" fg="${6:-white}" accent="${7:-00ccff}"
  nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error \
  -f lavfi -i color=c=${bg}:size=1280x720:duration=${dur}:rate=24 \
  -vf \"drawtext=text='${title}':fontsize=54:fontcolor=${fg}:x=(w-text_w)/2:y=(h-text_h)/2-50:fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf,drawtext=text='${subtitle}':fontsize=26:fontcolor=#${accent}:x=(w-text_w)/2:y=(h-text_h)/2+30:fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf\" \
  -c:v libx264 -preset fast -crf 20 '${out}'
" 2>/dev/null
}

# ── Step 1: Title card ────────────────────────────────────────────────────────
step "Step 1/6: Title card"
make_card "${OUTPUT_DIR}/s1_title.mp4" 4 \
  "AGH Creative Suite" "Your GPU. Your Canvas. No Limits." \
  "0x000a1a" "white" "00ccff"
success "Title card done."

# ── Step 2: AI brand images via ComfyUI API ───────────────────────────────────
step "Step 2/6: AI brand images (ComfyUI API)"

COMFYUI_URL="http://127.0.0.1:8188"

# Check ComfyUI is running
if curl -s --connect-timeout 3 "${COMFYUI_URL}/system_stats" &>/dev/null; then
  cmd "curl -X POST ${COMFYUI_URL}/prompt  # submitting image generation via ComfyUI API"
  info "This demonstrates: AI image generation — unlimited, no credits, no watermarks"

  PROMPTS=(
    "agh_workstation|A sleek futuristic AI creative workstation glowing with blue and purple light, multiple holographic screens showing AI-generated artwork, dark minimal setup, cinematic lighting, ultra detailed"
    "agh_creator|A confident creative professional in front of multiple screens showing stunning AI-generated videos and images, golden hour light, inspired expression, cinematic aspirational"
    "agh_abstract_ai|Abstract visualization of artificial intelligence creativity, flowing neural networks forming beautiful art, electric blue and purple particles, deep space background, 8K"
    "agh_gpu_power|An H100 GPU chip glowing with neon blue light, futuristic close-up macro shot, cinematic dramatic lighting, chrome and silicon textures"
    "agh_brand|The letters AGH formed from glowing light particles and energy trails against dark background, futuristic logo, electric blue and cyan, cinematic 8K"
    "agh_no_limits|A creative studio at night, screens glowing with AI-generated art, text NO LIMITS visible, inspiring atmosphere, cinematic wide shot"
  )

  for entry in "${PROMPTS[@]}"; do
    name="${entry%%|*}"
    prompt="${entry##*|}"
    out_path="${OUTPUT_DIR}/images/${name}.png"
    [[ -f "$out_path" ]] && { info "Already exists: ${name}.png"; continue; }

    info "Generating: ${name}..."
    # Submit workflow to ComfyUI
    PROMPT_ID=$(curl -s -X POST "${COMFYUI_URL}/prompt" \
      -H "Content-Type: application/json" \
      -d "{\"prompt\":{\"1\":{\"class_type\":\"CheckpointLoaderSimple\",\"inputs\":{\"ckpt_name\":\"v1-5-pruned-emaonly.safetensors\"}},\"2\":{\"class_type\":\"CLIPTextEncode\",\"inputs\":{\"text\":\"${prompt}\",\"clip\":[\"1\",1]}},\"3\":{\"class_type\":\"CLIPTextEncode\",\"inputs\":{\"text\":\"blurry, ugly, watermark, low quality\",\"clip\":[\"1\",1]}},\"4\":{\"class_type\":\"EmptyLatentImage\",\"inputs\":{\"width\":1280,\"height\":720,\"batch_size\":1}},\"5\":{\"class_type\":\"KSampler\",\"inputs\":{\"model\":[\"1\",0],\"positive\":[\"2\",0],\"negative\":[\"3\",0],\"latent_image\":[\"4\",0],\"seed\":42,\"steps\":25,\"cfg\":7.5,\"sampler_name\":\"euler\",\"scheduler\":\"normal\",\"denoise\":1}},\"6\":{\"class_type\":\"VAEDecode\",\"inputs\":{\"samples\":[\"5\",0],\"vae\":[\"1\",2]}},\"7\":{\"class_type\":\"SaveImage\",\"inputs\":{\"images\":[\"6\",0],\"filename_prefix\":\"${name}\"}}}}" \
      2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt_id',''))" 2>/dev/null || echo "")

    if [[ -z "$PROMPT_ID" ]]; then
      warn "ComfyUI rejected prompt for ${name} — skipping"
      continue
    fi

    # Wait for completion (up to 3 min per image)
    for i in $(seq 1 36); do
      sleep 5
      STATUS=$(curl -s "${COMFYUI_URL}/history/${PROMPT_ID}" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print('done' if d else 'waiting')" 2>/dev/null || echo "waiting")
      [[ "$STATUS" == "done" ]] && break
    done

    # Download generated image from ComfyUI output
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

  # Assemble slideshow from generated images
  if ls "${OUTPUT_DIR}/images"/*.png &>/dev/null 2>&1; then
    info "Assembling image slideshow..."
    SLIDE_CONCAT="${OUTPUT_DIR}/slides_concat.txt"; > "${SLIDE_CONCAT}"
    n=0
    for img in "${OUTPUT_DIR}/images"/*.png; do
      clip="${OUTPUT_DIR}/slide_${n}.mp4"
      nsenter -t "${POD_PID}" -m -- bash -c "
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
    show_output "AI Images" "${OUTPUT_DIR}/images"
  fi
else
  warn "ComfyUI not running on port 8188 — skipping AI images."
  warn "Start ComfyUI first or run setup_creative_suite.sh"
fi

# ── Step 3: AGH logo 3D reveal via Blender ────────────────────────────────────
step "Step 3/6: AGH logo 3D reveal (Blender)"

if [[ "$HAS_BLENDER" == "true" ]]; then
  cat > /tmp/agh_logo_blender.py << 'PYEOF'
import bpy, math

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete()

# Camera
bpy.ops.object.camera_add(location=(0, -12, 2))
cam = bpy.context.object
cam.rotation_euler = (math.radians(80), 0, 0)
bpy.context.scene.camera = cam

# AGH text
bpy.ops.object.text_add(location=(0, 0, 0))
txt = bpy.context.object
txt.data.body = "AGH"
txt.data.align_x = "CENTER"
txt.data.size = 2.0
txt.data.extrude = 0.3
txt.data.bevel_depth = 0.05
mat = bpy.data.materials.new("AGHMat")
mat.use_nodes = True
nodes = mat.node_tree.nodes
links = mat.node_tree.links
nodes.clear()
em = nodes.new("ShaderNodeEmission")
em.inputs["Color"].default_value = (0.0, 0.6, 1.0, 1.0)
em.inputs["Strength"].default_value = 3.0
out = nodes.new("ShaderNodeOutputMaterial")
links.new(em.outputs["Emission"], out.inputs["Surface"])
txt.data.materials.append(mat)
bpy.ops.object.convert(target='MESH')
txt.location = (-2.8, 0, 0)

# Scale reveal animation
txt.scale = (0, 0, 0)
txt.keyframe_insert("scale", frame=1)
txt.scale = (1.0, 1.0, 1.0)
txt.keyframe_insert("scale", frame=30)
txt.rotation_euler = (0, math.radians(90), 0)
txt.keyframe_insert("rotation_euler", frame=1)
txt.rotation_euler = (0, 0, 0)
txt.keyframe_insert("rotation_euler", frame=30)

# Tagline
bpy.ops.object.text_add(location=(-3.0, 0, -1.5))
tag = bpy.context.object
tag.data.body = "Creative Suite"
tag.data.size = 0.55
tag.data.extrude = 0.05
tm = bpy.data.materials.new("TagMat")
tm.use_nodes = True
tn = tm.node_tree.nodes; tn.clear()
te = tn.new("ShaderNodeEmission")
te.inputs["Color"].default_value = (0.8, 0.9, 1.0, 1.0)
te.inputs["Strength"].default_value = 1.5
to = tn.new("ShaderNodeOutputMaterial")
tm.node_tree.links.new(te.outputs["Emission"], to.inputs["Surface"])
tag.data.materials.append(tm)
bpy.ops.object.convert(target='MESH')
tag.scale = (0, 0, 0)
tag.keyframe_insert("scale", frame=35)
tag.scale = (1, 1, 1)
tag.keyframe_insert("scale", frame=55)

# Orbital rings
for i, (col, rad, tilt) in enumerate([
    ((0.0, 0.6, 1.0, 1.0), 4.5, 75),
    ((0.6, 0.1, 1.0, 1.0), 5.5, 45),
    ((0.0, 1.0, 0.8, 1.0), 6.5, 20),
]):
    bpy.ops.mesh.primitive_torus_add(
        major_radius=rad, minor_radius=0.04, location=(0, 0, 0),
        rotation=(math.radians(tilt), math.radians(i*30), 0))
    ring = bpy.context.object
    rm = bpy.data.materials.new(f"Ring{i}")
    rm.use_nodes = True
    rn = rm.node_tree.nodes; rn.clear()
    re = rn.new("ShaderNodeEmission")
    re.inputs["Color"].default_value = col
    re.inputs["Strength"].default_value = 2.5
    ro = rn.new("ShaderNodeOutputMaterial")
    rm.node_tree.links.new(re.outputs["Emission"], ro.inputs["Surface"])
    ring.data.materials.append(rm)
    ring.scale = (0, 0, 0)
    ring.keyframe_insert("scale", frame=max(1, 20 - i*5))
    ring.scale = (1, 1, 1)
    ring.keyframe_insert("scale", frame=40 + i*5)
    ring.keyframe_insert("rotation_euler", frame=1)
    ring.rotation_euler = (math.radians(tilt), math.radians(i*30 + 360), math.radians(360*(1+i*0.5)))
    ring.keyframe_insert("rotation_euler", frame=120)

# World
world = bpy.context.scene.world
world.use_nodes = True
bg = world.node_tree.nodes.get("Background")
if bg:
    bg.inputs["Color"].default_value = (0.0, 0.0, 0.02, 1.0)

# Render
scene = bpy.context.scene
scene.frame_start = 1
scene.frame_end = 120
scene.render.fps = 24
scene.render.resolution_x = 1280
scene.render.resolution_y = 720
scene.render.image_settings.file_format = "FFMPEG"
scene.render.ffmpeg.format = "MPEG4"
scene.render.ffmpeg.codec = "H264"
scene.render.ffmpeg.constant_rate_factor = "HIGH"
scene.render.filepath = "/tmp/agh_logo_out.mp4"
scene.render.engine = "BLENDER_EEVEE"
eevee = scene.eevee
if hasattr(eevee, "use_bloom"):
    eevee.use_bloom = True
    eevee.bloom_intensity = 1.2
    eevee.bloom_radius = 8.0
bpy.ops.render.render(animation=True)
print("BLENDER_DONE")
PYEOF

  BLENDER_B64=$(base64 -w0 /tmp/agh_logo_blender.py)
  cmd "blender --background --python agh_logo_blender.py  # headless 3D render, 120 frames @ 24fps"
  info "This demonstrates: 3D animation rendered on GPU via Blender EEVEE — no GUI needed"
  nsenter -t "${POD_PID}" -m -- bash -c "
echo '${BLENDER_B64}' | base64 -d > /tmp/agh_logo_blender.py
TMPDIR=${TMPDIR} blender --background --python /tmp/agh_logo_blender.py 2>&1 | grep -E 'BLENDER_DONE|Fra:|Error' | tail -10
cp /tmp/agh_logo_out.mp4 ${OUTPUT_DIR}/s3_logo.mp4 2>/dev/null || true
" && { success "AGH logo render done."; show_output "3D Logo Animation" "${OUTPUT_DIR}/s3_logo.mp4"; } || warn "Blender render failed."
else
  warn "Blender not found — skipping logo render."
fi

# ── Step 4: AI video via Wan2.1 ───────────────────────────────────────────────
step "Step 4/6: AI video (Wan2.1)"

if [[ "$HAS_WAN21" == "true" ]]; then
  cmd "python generate.py --task t2v-14B --size 1280*720 --sample_steps 50  # clip 1: futuristic workspace"
  info "This demonstrates: AI video generation — no 8-second limit, no watermarks, full GPU power"
  info "Commercial equivalent: RunwayML charges \$0.05/sec = ~\$3 for this clip. Cost here: \$0."
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/wan21-env/bin/activate
cd /opt/Wan2.1
TMPDIR=${TMPDIR} python generate.py \
  --task t2v-14B \
  --size 1280*720 \
  --ckpt_dir ${MODELS_DIR}/wan21 \
  --sample_steps 50 \
  --sample_guide_scale 6.0 \
  --prompt 'A futuristic AI creative studio. Holographic screens display stunning AI-generated artwork being created in real-time. Glowing particle effects flow between screens. Camera slowly pushes forward through the workspace. Deep blue and purple lighting. Cinematic, photorealistic, ultra smooth motion, 4K commercial quality.' \
  --save_file ${OUTPUT_DIR}/videos/wan21_workspace.mp4
" && {
    # Trim to 15s for reel
    nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error -i ${OUTPUT_DIR}/videos/wan21_workspace.mp4 \
  -t 15 -c:v libx264 -preset fast -crf 20 ${OUTPUT_DIR}/s4_video.mp4
"
    success "Wan2.1 video done."
    show_output "AI Video Clip 1" "${OUTPUT_DIR}/s4_video.mp4" "${OUTPUT_DIR}/videos/wan21_workspace.mp4"
  } || warn "Wan2.1 generation failed."

  # Second clip: GPU power shot
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/wan21-env/bin/activate
cd /opt/Wan2.1
TMPDIR=${TMPDIR} python generate.py \
  --task t2v-14B \
  --size 1280*720 \
  --ckpt_dir ${MODELS_DIR}/wan21 \
  --sample_steps 40 \
  --sample_guide_scale 6.0 \
  --prompt 'Abstract visualization of an AI generating an image, pixels assembling from noise into a stunning photorealistic landscape, time-lapse style, particle effects, glowing neural pathways, electric blue light, dramatic reveal, cinematic 4K.' \
  --save_file ${OUTPUT_DIR}/videos/wan21_ai_gen.mp4
" && {
    nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error -i ${OUTPUT_DIR}/videos/wan21_ai_gen.mp4 \
  -t 10 -c:v libx264 -preset fast -crf 20 ${OUTPUT_DIR}/s4b_video.mp4
"
    success "Wan2.1 second clip done."
    show_output "AI Video Clip 2" "${OUTPUT_DIR}/s4b_video.mp4"
  } || warn "Second clip failed — skipping."
else
  warn "Wan2.1 not installed — skipping AI video."
fi

# ── Step 5: Background music via MusicGen ─────────────────────────────────────
step "Step 5/6: Background music (MusicGen)"

if [[ "$HAS_MUSICGEN" == "true" ]]; then
  cmd "python -c 'MusicGen.get_pretrained(melody).generate([epic cinematic...])'  # 90s custom track"
  info "This demonstrates: AI music generation — custom track, no licensing fees, generated on demand"
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/audio-env/bin/activate
TMPDIR=${TMPDIR} python - << 'PYEOF'
from audiocraft.models import MusicGen
import torchaudio
m = MusicGen.get_pretrained('melody')
m.set_generation_params(duration=90)
audio = m.generate([
    'Epic cinematic orchestral music for a tech product reveal. '
    'Starts minimal and mysterious, builds with intensity, '
    'climaxes at 30 seconds with full orchestra and electronic elements, '
    'inspiring and futuristic, suitable for a premium AI technology advertisement'
])[0].cpu()
torchaudio.save('${OUTPUT_DIR}/music.wav', audio, 32000)
print('Music saved')
PYEOF
" && { success "Background music generated."; show_output "Background Music" "${OUTPUT_DIR}/music.wav"; } || warn "MusicGen failed — no music in final reel."
fi

# ── Step 6: Section cards + final assembly ────────────────────────────────────
step "Step 6/6: Assembly"

# Section cards
[[ -f "${OUTPUT_DIR}/s2_images.mp4" ]] && \
  make_card "${OUTPUT_DIR}/card_images.mp4" 2 "AI Image Generation" "Unlimited · No Credits · No Watermarks" "0x001a0a" "white" "00ff88"
[[ -f "${OUTPUT_DIR}/s3_logo.mp4" ]] && \
  make_card "${OUTPUT_DIR}/card_3d.mp4" 2 "3D Animation" "Blender — Real-time GPU Render" "0x050020" "white" "8833ff"
[[ -f "${OUTPUT_DIR}/s4_video.mp4" ]] && \
  make_card "${OUTPUT_DIR}/card_video.mp4" 2 "AI Video Generation" "Wan2.1 — No Time Limits" "0x1a0500" "white" "ff6600"

# End card with tagline
PORTAL_URL=$(grep -o 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' /tmp/cf-tunnel-portal.log 2>/dev/null | head -1 || echo "aghcloud.ai")
make_card "${OUTPUT_DIR}/card_end.mp4" 6 \
  "AGH Creative Suite" "This video was made using AGH Creative Suite" \
  "0x000a1a" "white" "00ccff"

# Build concat list
CONCAT="${OUTPUT_DIR}/concat.txt"
> "${CONCAT}"
echo "file '${OUTPUT_DIR}/s1_title.mp4'" >> "${CONCAT}"
[[ -f "${OUTPUT_DIR}/card_images.mp4" ]] && echo "file '${OUTPUT_DIR}/card_images.mp4'" >> "${CONCAT}"
[[ -f "${OUTPUT_DIR}/s2_images.mp4" ]]   && echo "file '${OUTPUT_DIR}/s2_images.mp4'" >> "${CONCAT}"
[[ -f "${OUTPUT_DIR}/card_3d.mp4" ]]     && echo "file '${OUTPUT_DIR}/card_3d.mp4'" >> "${CONCAT}"
[[ -f "${OUTPUT_DIR}/s3_logo.mp4" ]]     && echo "file '${OUTPUT_DIR}/s3_logo.mp4'" >> "${CONCAT}"
[[ -f "${OUTPUT_DIR}/card_video.mp4" ]]  && echo "file '${OUTPUT_DIR}/card_video.mp4'" >> "${CONCAT}"
[[ -f "${OUTPUT_DIR}/s4_video.mp4" ]]    && echo "file '${OUTPUT_DIR}/s4_video.mp4'" >> "${CONCAT}"
[[ -f "${OUTPUT_DIR}/s4b_video.mp4" ]]   && echo "file '${OUTPUT_DIR}/s4b_video.mp4'" >> "${CONCAT}"
echo "file '${OUTPUT_DIR}/card_end.mp4'" >> "${CONCAT}"

FINAL="${OUTPUT_DIR}/AGH_Creative_Suite_Promo.mp4"

if [[ -f "${OUTPUT_DIR}/music.wav" ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error \
  -f concat -safe 0 -i ${CONCAT} \
  -i ${OUTPUT_DIR}/music.wav \
  -filter_complex '[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1[v];[1:a]volume=0.35,afade=t=out:st=85:d=4[a]' \
  -map '[v]' -map '[a]' \
  -c:v libx264 -preset fast -crf 18 -c:a aac -b:a 192k -shortest \
  ${FINAL}
" && { success "Final promo with music: ${FINAL}"; show_output "FINAL PROMO VIDEO" "${FINAL}"; } || warn "Assembly failed."
else
  nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -loglevel error \
  -f concat -safe 0 -i ${CONCAT} \
  -vf 'scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1' \
  -c:v libx264 -preset fast -crf 18 \
  ${FINAL}
" && { success "Final promo (no music): ${FINAL}"; show_output "FINAL PROMO VIDEO" "${FINAL}"; } || warn "Assembly failed."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
TOTAL_TIME=$(( $(date +%s) - STEP_START ))

ulog ""
ulog "════════════════════════════════════════════════════════════════"
ulog "  AGH Promo Video Complete!"
ulog "════════════════════════════════════════════════════════════════"
ulog ""
ulog "  Finished:  $(date '+%Y-%m-%d %H:%M:%S')"
ulog "  GPU used:  ${GPU_NAME}"
ulog ""
ulog "  WHAT JUST HAPPENED (automatically, zero human input):"
[[ -f "${OUTPUT_DIR}/s2_images.mp4" ]] && ulog "  ✓ AI brand images generated      — ComfyUI"
[[ -f "${OUTPUT_DIR}/s3_logo.mp4" ]]   && ulog "  ✓ AGH logo 3D animation rendered — Blender EEVEE headless"
[[ -f "${OUTPUT_DIR}/s4_video.mp4" ]]  && ulog "  ✓ AI video clips generated       — Wan2.1 14B model"
[[ -f "${OUTPUT_DIR}/music.wav" ]]     && ulog "  ✓ Background music created        — MusicGen"
[[ -f "${FINAL}" ]]                    && ulog "  ✓ Final video assembled          — FFmpeg"
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
ulog "  scp ${KEY_ARG}-r shadeform@${SERVER_IP}:${OUTPUT_DIR}/ ~/Desktop/agh-promo/"
ulog ""
ulog "  This video was made entirely using AGH Creative Suite."
ulog "  You are watching the product."
ulog ""
