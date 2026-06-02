#!/usr/bin/env bash
# AGH Creative Suite — Demo Video Generator
#
# Creates a 60-second demo reel showing:
#   - AI video generation via Wan2.1 (no time limits)
#   - 3D animation via Blender (headless render)
#   - Final edit assembled with FFmpeg
#
# Run inside the Shadeform VM after setup_creative_suite.sh completes.
# Usage: bash demo_creative_suite.sh
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }

[[ $EUID -eq 0 ]] || { echo -e "${RED}[ERROR]${NC} Run as root: sudo bash $0"; exit 1; }

OUTPUT_DIR="/tmp/agh-demo"
mkdir -p "${OUTPUT_DIR}/frames"

# ── Demo prompt ───────────────────────────────────────────────────────────────
VIDEO_PROMPT="A cinematic timelapse of a futuristic city at golden hour. Flying vehicles streak across glowing skyscrapers. Camera slowly pulls back to reveal the full skyline. Ultra detailed, photorealistic, smooth motion, 4K quality."

POD_PID=$(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | head -1)
[[ -n "$POD_PID" ]] || { echo -e "${RED}[ERROR]${NC} Pod not running. Run setup_creative_suite.sh first."; exit 1; }

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        AGH Creative Suite — Demo Video Generator         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
info "Output directory: ${OUTPUT_DIR}"
info "Prompt: ${VIDEO_PROMPT}"
echo ""

# ── Step 1: AI Video via Wan2.1 (~30 seconds of generation) ──────────────────
step "Step 1/3: Generating AI video with Wan2.1 (no time limits)"

if [[ -d /opt/Wan2.1 ]] && [[ -d /opt/models/wan21 ]]; then
  info "Installing missing dependencies..."
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/wan21-env/bin/activate
pip install --quiet easydict
"
  nsenter -t "${POD_PID}" -m -- bash -c "
set -e
source /opt/wan21-env/bin/activate
cd /opt/Wan2.1
python generate.py \
  --task t2v-14B \
  --size 1280*720 \
  --ckpt_dir /opt/models/wan21 \
  --sample_steps 50 \
  --sample_guide_scale 6.0 \
  --prompt \"${VIDEO_PROMPT}\" \
  --save_file ${OUTPUT_DIR}/ai_video.mp4
" && success "AI video saved: ${OUTPUT_DIR}/ai_video.mp4" \
  || warn "Wan2.1 generation failed. Check /opt/models/wan21 exists."
else
  warn "Wan2.1 not installed. Skipping AI video generation."
  warn "Re-run setup_creative_suite.sh and select Wan2.1 (option 4)."
fi

# ── Step 2: 3D Animation via Blender (headless render) ───────────────────────
step "Step 2/3: Rendering 3D animation with Blender"

# Write Blender scene script INSIDE pod's mount namespace, then run blender
nsenter -t "${POD_PID}" -m -- bash -c 'cat > /tmp/blender_demo_scene.py << '"'"'BLENDER_SCRIPT'"'"'
import bpy
import math

# Clear default scene
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()

# ── Camera ──
bpy.ops.object.camera_add(location=(0, -8, 3))
cam = bpy.context.object
cam.rotation_euler = (math.radians(70), 0, 0)
bpy.context.scene.camera = cam

# ── Main sphere (glowing) ──
bpy.ops.mesh.primitive_uv_sphere_add(radius=1.5, location=(0, 0, 0))
sphere = bpy.context.object
sphere.name = "CoreSphere"

mat = bpy.data.materials.new(name="GlowMaterial")
mat.use_nodes = True
nodes = mat.node_tree.nodes
nodes.clear()

emission = nodes.new('ShaderNodeEmission')
emission.inputs['Color'].default_value = (0.2, 0.6, 1.0, 1.0)
emission.inputs['Strength'].default_value = 5.0

output = nodes.new('ShaderNodeOutputMaterial')
mat.node_tree.links.new(emission.outputs['Emission'], output.inputs['Surface'])
sphere.data.materials.append(mat)

# Animate rotation
sphere.rotation_euler = (0, 0, 0)
sphere.keyframe_insert(data_path="rotation_euler", frame=1)
sphere.rotation_euler = (0, 0, math.radians(360))
sphere.keyframe_insert(data_path="rotation_euler", frame=120)

# ── Orbital rings ──
for i, (scale, color) in enumerate([
    (2.2, (0.0, 0.8, 1.0, 1.0)),
    (2.8, (0.5, 0.2, 1.0, 1.0)),
    (3.4, (1.0, 0.4, 0.0, 1.0)),
]):
    bpy.ops.mesh.primitive_torus_add(
        major_radius=scale, minor_radius=0.05,
        location=(0, 0, 0),
        rotation=(math.radians(90 * (i % 2)), math.radians(30 * i), 0)
    )
    ring = bpy.context.object
    ring.name = f"Ring_{i}"

    ring_mat = bpy.data.materials.new(name=f"RingMat_{i}")
    ring_mat.use_nodes = True
    ring_nodes = ring_mat.node_tree.nodes
    ring_nodes.clear()
    ring_emission = ring_nodes.new('ShaderNodeEmission')
    ring_emission.inputs['Color'].default_value = color
    ring_emission.inputs['Strength'].default_value = 3.0
    ring_output = ring_nodes.new('ShaderNodeOutputMaterial')
    ring_mat.node_tree.links.new(ring_emission.outputs['Emission'], ring_output.inputs['Surface'])
    ring.data.materials.append(ring_mat)

    ring.keyframe_insert(data_path="rotation_euler", frame=1)
    ring.rotation_euler[2] += math.radians(360)
    ring.keyframe_insert(data_path="rotation_euler", frame=120)

# ── World (dark background) ──
world = bpy.context.scene.world
world.use_nodes = True
bg = world.node_tree.nodes.get('Background')
if bg:
    bg.inputs['Color'].default_value = (0.0, 0.0, 0.05, 1.0)
    bg.inputs['Strength'].default_value = 1.0

# ── Render settings ──
scene = bpy.context.scene
scene.frame_start = 1
scene.frame_end = 120          # 5 seconds at 24fps
scene.render.fps = 24
scene.render.resolution_x = 1280
scene.render.resolution_y = 720
scene.render.image_settings.file_format = 'FFMPEG'
scene.render.ffmpeg.format = 'MPEG4'
scene.render.ffmpeg.codec = 'H264'
scene.render.filepath = '/tmp/agh-demo/blender_animation.mp4'

# Use EEVEE for fast GPU render
scene.render.engine = 'BLENDER_EEVEE_NEXT'
eevee = scene.eevee
eevee.use_bloom = True
eevee.bloom_intensity = 0.5

bpy.ops.render.render(animation=True)
print("Blender render complete.")
BLENDER_SCRIPT
blender --background --python /tmp/blender_demo_scene.py 2>&1 | tail -5
' && success "Blender animation saved: ${OUTPUT_DIR}/blender_animation.mp4" \
  || warn "Blender render failed. Check blender is installed."

# ── Step 3: Assemble final demo reel with FFmpeg ──────────────────────────────
step "Step 3/3: Assembling final demo reel with FFmpeg"

# Build concat list from whatever was generated
CONCAT_FILE="/tmp/agh-demo/concat.txt"
> "${CONCAT_FILE}"

[[ -f "${OUTPUT_DIR}/ai_video.mp4" ]]        && echo "file '${OUTPUT_DIR}/ai_video.mp4'"        >> "${CONCAT_FILE}"
[[ -f "${OUTPUT_DIR}/blender_animation.mp4" ]] && echo "file '${OUTPUT_DIR}/blender_animation.mp4'" >> "${CONCAT_FILE}"

if [[ ! -s "${CONCAT_FILE}" ]]; then
  warn "No video clips generated. Nothing to assemble."
  exit 1
fi

# Add title card at start
nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y \
  -f lavfi -i color=c=0x000a1a:size=1280x720:duration=3:rate=24 \
  -vf \"drawtext=text='AGH Creative Suite':fontsize=64:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2-40:fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf,
       drawtext=text='Powered by GPU — No Limits':fontsize=28:fontcolor=cyan:x=(w-text_w)/2:y=(h-text_h)/2+40:fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf\" \
  ${OUTPUT_DIR}/title_card.mp4 2>/dev/null
"

# Prepend title card
[[ -f "${OUTPUT_DIR}/title_card.mp4" ]] && \
  sed -i "1s|^|file '${OUTPUT_DIR}/title_card.mp4'\n|" "${CONCAT_FILE}"

# Final concat
nsenter -t "${POD_PID}" -m -- bash -c "
ffmpeg -y -f concat -safe 0 -i ${CONCAT_FILE} \
  -c:v libx264 -preset fast -crf 20 \
  -vf 'scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2' \
  ${OUTPUT_DIR}/AGH_Creative_Suite_Demo.mp4
" && success "Final demo reel: ${OUTPUT_DIR}/AGH_Creative_Suite_Demo.mp4" \
  || warn "FFmpeg assembly failed."

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║              Demo Video Ready!                           ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Output files:${NC}"
[[ -f "${OUTPUT_DIR}/ai_video.mp4" ]]               && echo -e "  ${GREEN}•${NC} AI video (Wan2.1):    ${OUTPUT_DIR}/ai_video.mp4"
[[ -f "${OUTPUT_DIR}/blender_animation.mp4" ]]      && echo -e "  ${GREEN}•${NC} 3D animation (Blender): ${OUTPUT_DIR}/blender_animation.mp4"
[[ -f "${OUTPUT_DIR}/AGH_Creative_Suite_Demo.mp4" ]] && echo -e "  ${GREEN}•${NC} Final demo reel:      ${OUTPUT_DIR}/AGH_Creative_Suite_Demo.mp4"
echo ""
echo -e "${BOLD}Copy to your laptop:${NC}"
echo -e "  ${CYAN}scp shadeform@<SERVER_IP>:${OUTPUT_DIR}/AGH_Creative_Suite_Demo.mp4 ~/Desktop/${NC}"
echo ""
