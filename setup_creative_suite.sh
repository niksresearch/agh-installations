#!/usr/bin/env bash
# AGH Creative Suite — Full AI Creative Workstation Setup
#
# One-line install:
#   wget -qO setup_creative_suite.sh https://raw.githubusercontent.com/niksresearch/agh-installations/main/setup_creative_suite.sh && sudo bash setup_creative_suite.sh
#
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DATA_DIR="/opt"
MODELS_DIR="/opt/models"
APPS_DIR="/opt/apps"
LOGS_DIR="/tmp/creative-suite-logs"
TMPDIR_OVERRIDE="/tmp"
SELECTED_APPS=""
POD_PID=""

# ── Auto-detect and mount extra data disk ────────────────────────────────────
# Shadeform (and most GPU cloud) VMs ship with a second unmounted disk for data.
# If found, we mount it at /data and redirect all large model downloads there
# so the root partition never fills up. Totally transparent to the user.
mount_data_disk() {
  # Check common pre-mounted large-disk paths (Shadeform uses /ephemeral, others use /data or /mnt)
  for candidate in /ephemeral /data /mnt/data /mnt; do
    if mountpoint -q "${candidate}" 2>/dev/null; then
      local avail
      avail=$(df -BG "${candidate}" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
      if [[ "${avail:-0}" -gt 50 ]]; then
        info "Large disk found at ${candidate} (${avail}GB free). Using it for models and apps."
        DATA_DIR="${candidate}"
        MODELS_DIR="${candidate}/models"
        APPS_DIR="${candidate}/apps"
        TMPDIR_OVERRIDE="${candidate}/tmp"
        return 0
      fi
    fi
  done

  # No pre-mounted large disk — find the largest unmounted block device
  local best_dev="" best_size=0
  while IFS= read -r line; do
    local dev size
    dev=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $4}')
    # Skip if already mounted
    lsblk -n -o MOUNTPOINT "/dev/${dev}" 2>/dev/null | grep -q '[^[:space:]]' && continue
    [[ "${size:-0}" -gt "$best_size" ]] 2>/dev/null && { best_size="$size"; best_dev="$dev"; }
  done < <(lsblk -d -n -b -o NAME,TYPE,SIZE | awk '$2=="disk"' | grep -v "^loop" || true)

  if [[ -z "$best_dev" ]]; then
    info "No extra data disk detected. Using root partition."
    return 0
  fi

  local dev_path="/dev/${best_dev}"
  info "Found unmounted disk: ${dev_path} ($(lsblk -d -n -o SIZE "${dev_path}")). Mounting at /data..."

  if ! blkid "${dev_path}" &>/dev/null; then
    info "Formatting ${dev_path} as ext4..."
    mkfs.ext4 -F "${dev_path}" >/dev/null 2>&1
  fi

  mkdir -p /data
  mount "${dev_path}" /data

  local uuid
  uuid=$(blkid -s UUID -o value "${dev_path}")
  if ! grep -q "${uuid}" /etc/fstab 2>/dev/null; then
    echo "UUID=${uuid} /data ext4 defaults 0 2" >> /etc/fstab
  fi

  DATA_DIR="/data"
  MODELS_DIR="/data/models"
  APPS_DIR="/data/apps"
  TMPDIR_OVERRIDE="/data/tmp"
  success "Data disk mounted at /data. Models and apps stored there (root partition stays free)."
}

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }

banner() {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║      AGH Creative Suite — AI Workstation Setup           ║"
  echo "║      Video · Image · Audio · No Limits                   ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

[[ $EUID -eq 0 ]] || { error "Run as root: sudo bash $0"; exit 1; }

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "not detected")
info "Host: $(hostname)  |  GPU: ${GPU_NAME}  |  Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# Detect and use large data disk before any installs
mount_data_disk
mkdir -p "${MODELS_DIR}" "${APPS_DIR}" "${LOGS_DIR}" "${TMPDIR_OVERRIDE}"
export TMPDIR="${TMPDIR_OVERRIDE}"

# ── Password prompt ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Set a password for the virtual desktop:${NC}"
echo -e "${CYAN}(Minimum 6 characters — used to access the desktop from your browser)${NC}"
echo ""
VNC_PASS=""
while true; do
  read -rsp "$(echo -e "${BOLD}Password:${NC} ")" VNC_PASS
  echo ""
  if [[ ${#VNC_PASS} -lt 6 ]]; then
    warn "Password must be at least 6 characters. Try again."
    continue
  fi
  read -rsp "$(echo -e "${BOLD}Confirm password:${NC} ")" VNC_PASS2
  echo ""
  if [[ "$VNC_PASS" == "$VNC_PASS2" ]]; then
    break
  else
    warn "Passwords do not match. Try again."
  fi
done
success "Password accepted."
export VNC_PASS

# ── App selection — Tier 2 custom checklist ───────────────────────────────────
show_custom_menu() {
  echo ""
  echo -e "${BOLD}Select apps to install (space-separated numbers, or 'all'):${NC}"
  echo ""
  echo -e "  ${BOLD}AI Image Generation:${NC}"
  echo -e "  ${CYAN}[1]${NC}  FLUX model (via ComfyUI)       (~24GB, ~15min)"
  echo -e "  ${CYAN}[2]${NC}  Stable Diffusion WebUI/A1111   (~4GB,  ~5min)"
  echo ""
  echo -e "  ${BOLD}AI Video Generation — no time limits:${NC}"
  echo -e "  ${CYAN}[3]${NC}  HunyuanVideo                   (~87GB, ~30min) ⚠️  best quality"
  echo -e "  ${CYAN}[4]${NC}  Wan2.1                         (~14GB, ~10min)    ← recommended"
  echo -e "  ${CYAN}[5]${NC}  LTX-Video                      (~8GB,  ~5min)     fast prototyping"
  echo -e "  ${CYAN}[6]${NC}  CogVideoX-5B                   (~20GB, ~12min)"
  echo ""
  echo -e "  ${BOLD}AI Enhancement:${NC}"
  echo -e "  ${CYAN}[7]${NC}  Real-ESRGAN + RIFE             (~500MB, ~2min)    upscale + smooth"
  echo ""
  echo -e "  ${BOLD}AI Audio & Voice:${NC}"
  echo -e "  ${CYAN}[8]${NC}  MusicGen + Demucs              (~5.5GB, ~5min)    generate + separate music"
  echo -e "  ${CYAN}[9]${NC}  Bark TTS / OpenVoice           (~5GB,   ~5min)"
  echo ""
  echo -e "  ${BOLD}Dev Tools:${NC}"
  echo -e "  ${CYAN}[10]${NC} VS Code + JupyterLab           (~500MB, ~3min)"
  echo ""

  read -rp "$(echo -e "${BOLD}Enter choices (e.g. \"1 4 5 7\" or \"all\"):${NC} ")" raw_choices

  declare -A app_map
  app_map[1]="flux" app_map[2]="a1111" app_map[3]="hunyuan" app_map[4]="wan21"
  app_map[5]="ltx"  app_map[6]="cogvideo" app_map[7]="esrgan"
  app_map[8]="musicgen" app_map[9]="bark" app_map[10]="devtools"

  if [[ "$raw_choices" == "all" ]]; then
    SELECTED_APPS="flux a1111 hunyuan wan21 ltx cogvideo esrgan musicgen bark devtools"
  else
    SELECTED_APPS=""
    for num in $raw_choices; do
      [[ -n "${app_map[$num]:-}" ]] && SELECTED_APPS="${SELECTED_APPS} ${app_map[$num]}"
    done
    SELECTED_APPS="${SELECTED_APPS# }"
  fi

  [[ -z "$SELECTED_APPS" ]] && warn "No apps selected. Installing core tools only."
}

# ── App selection — Tier 1 bundle picker ─────────────────────────────────────
echo ""
echo -e "${BOLD}Always installed:${NC} GIMP, Krita, Kdenlive, Audacity, Inkscape, ComfyUI, FFmpeg, Blender, WhisperX"
echo ""
echo -e "${BOLD}Select a package:${NC}"
echo ""
echo -e "  ${CYAN}[1]${NC} ${BOLD}Starter${NC}      Core tools + Wan2.1 + FLUX          (~40GB,  ~20min)"
echo -e "         GIMP, Krita, Kdenlive, ComfyUI + FLUX model + Wan2.1 + Real-ESRGAN"
echo ""
echo -e "  ${CYAN}[2]${NC} ${BOLD}Creator${NC}      Starter + HunyuanVideo + Audio       (~140GB, ~60min)"
echo -e "         Everything in Starter + HunyuanVideo + MusicGen + Bark TTS"
echo ""
echo -e "  ${CYAN}[3]${NC} ${BOLD}Full Suite${NC}   Everything                           (~170GB, ~90min)"
echo -e "         All apps + all AI models"
echo ""
echo -e "  ${CYAN}[4]${NC} ${BOLD}Custom${NC}       Pick your own apps"
echo ""

while true; do
  read -rp "$(echo -e "${BOLD}Enter choice [1-4]:${NC} ")" bundle_choice
  case "$bundle_choice" in
    1) SELECTED_APPS="flux wan21 esrgan"; break ;;
    2) SELECTED_APPS="flux wan21 hunyuan musicgen bark esrgan"; break ;;
    3) SELECTED_APPS="flux a1111 hunyuan wan21 ltx cogvideo esrgan musicgen bark devtools"; break ;;
    4) show_custom_menu; break ;;
    *) warn "Enter 1, 2, 3, or 4." ;;
  esac
done

info "Selected: ${SELECTED_APPS:-core tools only}"

# ── Install functions ─────────────────────────────────────────────────────────

install_flux() {
  info "Downloading FLUX.1-dev model (~24GB)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/comfyui-env/bin/activate
hf download black-forest-labs/FLUX.1-dev \
  flux1-dev.safetensors \
  --local-dir /opt/ComfyUI/models/unet/ \
  --local-dir-use-symlinks False
hf download comfyanonymous/flux_text_encoders \
  clip_l.safetensors t5xxl_fp8_e4m3fn.safetensors \
  --local-dir /opt/ComfyUI/models/clip/ \
  --local-dir-use-symlinks False
hf download black-forest-labs/FLUX.1-dev \
  ae.safetensors \
  --local-dir /opt/ComfyUI/models/vae/ \
  --local-dir-use-symlinks False
" && success "FLUX model downloaded." || warn "FLUX download failed — retry: hf download black-forest-labs/FLUX.1-dev"
}

install_a1111() {
  info "Installing Stable Diffusion WebUI (A1111)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui /opt/stable-diffusion-webui 2>/dev/null || \
  (cd /opt/stable-diffusion-webui && git pull)
python3 -m venv /opt/a1111-env
source /opt/a1111-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet -r /opt/stable-diffusion-webui/requirements.txt
mkdir -p /opt/stable-diffusion-webui/models/Stable-diffusion
hf download runwayml/stable-diffusion-v1-5 \
  v1-5-pruned-emaonly.safetensors \
  --local-dir /opt/stable-diffusion-webui/models/Stable-diffusion/ \
  --local-dir-use-symlinks False
" && success "A1111 installed." || warn "A1111 install failed."
}

install_hunyuan() {
  info "Installing HunyuanVideo (~87GB — takes ~30 minutes)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
git clone https://github.com/Tencent/HunyuanVideo /opt/HunyuanVideo 2>/dev/null || \
  (cd /opt/HunyuanVideo && git pull)
python3 -m venv /opt/hunyuan-env
source /opt/hunyuan-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet -r /opt/HunyuanVideo/requirements.txt
mkdir -p ${MODELS_DIR}/hunyuan
hf download tencent/HunyuanVideo \
  --local-dir ${MODELS_DIR}/hunyuan \
  --local-dir-use-symlinks False
" && success "HunyuanVideo installed." || warn "HunyuanVideo install failed."
}

install_wan21() {
  info "Installing Wan2.1 (~14GB)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
git clone https://github.com/Wan-Video/Wan2.1 /opt/Wan2.1 2>/dev/null || \
  (cd /opt/Wan2.1 && git pull)
python3 -m venv /opt/wan21-env
source /opt/wan21-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet diffusers transformers accelerate easydict
pip install --quiet -r /opt/Wan2.1/requirements.txt
pip install --quiet huggingface_hub
pip install flash-attn --no-build-isolation --quiet 2>/dev/null || \
  echo '[WARN] flash-attn compile failed — patching to use PyTorch sdp fallback'
mkdir -p ${MODELS_DIR}/wan21
hf download Wan-AI/Wan2.1-T2V-14B \
  --local-dir ${MODELS_DIR}/wan21 \
  --local-dir-use-symlinks False

# Patch attention.py to fall back to torch sdp when flash-attn unavailable
python3 - << 'PYEOF'
import sys
path = '/opt/Wan2.1/wan/modules/attention.py'
with open(path) as f:
    src = f.read()
old = '''        assert FLASH_ATTN_2_AVAILABLE
        x = flash_attn.flash_attn_varlen_func(
            q=q,
            k=k,
            v=v,
            cu_seqlens_q=torch.cat([q_lens.new_zeros([1]), q_lens]).cumsum(
                0, dtype=torch.int32).to(q.device, non_blocking=True),
            cu_seqlens_k=torch.cat([k_lens.new_zeros([1]), k_lens]).cumsum(
                0, dtype=torch.int32).to(q.device, non_blocking=True),
            max_seqlen_q=lq,
            max_seqlen_k=lk,
            dropout_p=dropout_p,
            softmax_scale=softmax_scale,
            causal=causal,
            window_size=window_size,
            deterministic=deterministic).unflatten(0, (b, lq))'''
new = '''        if FLASH_ATTN_2_AVAILABLE:
            x = flash_attn.flash_attn_varlen_func(
                q=q,
                k=k,
                v=v,
                cu_seqlens_q=torch.cat([q_lens.new_zeros([1]), q_lens]).cumsum(
                    0, dtype=torch.int32).to(q.device, non_blocking=True),
                cu_seqlens_k=torch.cat([k_lens.new_zeros([1]), k_lens]).cumsum(
                    0, dtype=torch.int32).to(q.device, non_blocking=True),
                max_seqlen_q=lq,
                max_seqlen_k=lk,
                dropout_p=dropout_p,
                softmax_scale=softmax_scale,
                causal=causal,
                window_size=window_size,
                deterministic=deterministic).unflatten(0, (b, lq))
        else:
            import torch.nn.functional as F
            q_b = q.unflatten(0, (b, lq)).permute(0, 2, 1, 3)
            k_b = k.unflatten(0, (b, lk)).permute(0, 2, 1, 3)
            v_b = v.unflatten(0, (b, lk)).permute(0, 2, 1, 3)
            x = F.scaled_dot_product_attention(
                q_b, k_b, v_b,
                dropout_p=dropout_p,
                scale=softmax_scale,
                is_causal=causal,
            ).permute(0, 2, 1, 3)'''
if old in src:
    with open(path, 'w') as f:
        f.write(src.replace(old, new))
    print('attention.py patched for sdp fallback')
else:
    print('attention.py already patched or pattern changed')
PYEOF

# Simple Gradio web UI for Wan2.1 (port 7870)
pip install --quiet gradio
cat > /opt/Wan2.1/gradio_app.py << 'GRADEOF'
import gradio as gr, subprocess, os, time

MODELS_DIR = os.environ.get("AGH_MODELS", "/opt/models")
TMPDIR = os.environ.get("TMPDIR", "/tmp")

def generate_video(prompt, steps, guidance, width, height):
    out = f"{TMPDIR}/wan21_{int(time.time())}.mp4"
    cmd = [
        "python", "generate.py",
        "--task", "t2v-14B",
        "--size", f"{width}*{height}",
        "--ckpt_dir", f"{MODELS_DIR}/wan21",
        "--sample_steps", str(steps),
        "--sample_guide_scale", str(guidance),
        "--prompt", prompt,
        "--save_file", out,
    ]
    env = os.environ.copy()
    env["TMPDIR"] = TMPDIR
    result = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd="/opt/Wan2.1")
    if os.path.exists(out):
        return out, "Generation complete."
    return None, result.stderr[-2000:] if result.stderr else "Generation failed."

with gr.Blocks(title="Wan2.1 Video Generator", theme=gr.themes.Soft()) as demo:
    gr.Markdown("# Wan2.1 AI Video Generator\nGenerate videos up to 2+ minutes — no time limits.")
    with gr.Row():
        with gr.Column(scale=2):
            prompt = gr.Textbox(label="Prompt", lines=4,
                placeholder="A cinematic timelapse of a futuristic city at golden hour...")
            with gr.Row():
                steps    = gr.Slider(10, 100, value=50, step=5, label="Steps")
                guidance = gr.Slider(1, 15, value=6, step=0.5, label="Guidance Scale")
            with gr.Row():
                width  = gr.Dropdown([1280, 854, 640], value=1280, label="Width")
                height = gr.Dropdown([720, 480, 360], value=720, label="Height")
            btn = gr.Button("Generate Video", variant="primary", size="lg")
        with gr.Column(scale=2):
            video_out = gr.Video(label="Generated Video")
            status    = gr.Textbox(label="Status", interactive=False)
    btn.click(generate_video, inputs=[prompt, steps, guidance, width, height],
              outputs=[video_out, status])

demo.launch(server_name="0.0.0.0", server_port=7870, share=False)
GRADEOF
" && success "Wan2.1 installed with Gradio UI on port 7870." || warn "Wan2.1 install failed."
}

install_ltx() {
  info "Installing LTX-Video (~8GB — fast generation)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
python3 -m venv /opt/ltx-env
source /opt/ltx-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet 'ltx-video' diffusers transformers accelerate
mkdir -p ${MODELS_DIR}/ltx
hf download Lightricks/LTX-Video \
  --local-dir ${MODELS_DIR}/ltx \
  --local-dir-use-symlinks False
" && success "LTX-Video installed." || warn "LTX-Video install failed."
}

install_cogvideo() {
  info "Installing CogVideoX-5B (~20GB)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
python3 -m venv /opt/cogvideo-env
source /opt/cogvideo-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet diffusers transformers accelerate 'imageio[ffmpeg]'
mkdir -p ${MODELS_DIR}/cogvideo
hf download THUDM/CogVideoX-5b \
  --local-dir ${MODELS_DIR}/cogvideo \
  --local-dir-use-symlinks False
" && success "CogVideoX-5B installed." || warn "CogVideoX install failed."
}

install_esrgan() {
  info "Installing Real-ESRGAN + RIFE (~500MB)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
python3 -m venv /opt/enhancement-env
source /opt/enhancement-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet realesrgan basicsr
mkdir -p ${MODELS_DIR}/realesrgan
wget -qO ${MODELS_DIR}/realesrgan/RealESRGAN_x4plus.pth \
  https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth
git clone https://github.com/hzwer/ECCV2022-RIFE /opt/RIFE 2>/dev/null || true
" && success "Real-ESRGAN + RIFE installed." || warn "Enhancement tools install failed."
}

install_musicgen() {
  info "Installing MusicGen + Demucs (~5.5GB)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
python3 -m venv /opt/audio-env
source /opt/audio-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet audiocraft
pip install --quiet demucs
" && success "MusicGen + Demucs installed." || warn "Audio tools install failed."
}

install_bark() {
  info "Installing Bark TTS + OpenVoice (~5GB)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
python3 -m venv /opt/voice-env
source /opt/voice-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet bark
git clone https://github.com/myshell-ai/OpenVoice /opt/OpenVoice 2>/dev/null || \
  (cd /opt/OpenVoice && git pull)
pip install --quiet -r /opt/OpenVoice/requirements.txt
" && success "Bark TTS + OpenVoice installed." || warn "Voice tools install failed."
}

install_devtools() {
  info "Installing VS Code (code-server) + JupyterLab..."
  nsenter -t "${POD_PID}" -m -- bash -c "
curl -fsSL https://code-server.dev/install.sh | sh
python3 -m venv /opt/jupyter-env
source /opt/jupyter-env/bin/activate
pip install --quiet jupyterlab
" && success "VS Code + JupyterLab installed." || warn "Dev tools install failed."
}

# ── Phase 2: Desktop setup ────────────────────────────────────────────────────
step "Phase 2/5: Setting up virtual desktop (XFCE + VNC + cloudflared)"

DESKTOP_SCRIPT_URL="https://raw.githubusercontent.com/niksresearch/agh-installations/main/setup_desktop.sh"
info "Downloading setup_desktop.sh..."
wget -qO /tmp/setup_desktop.sh "${DESKTOP_SCRIPT_URL}"
chmod +x /tmp/setup_desktop.sh

info "Running desktop setup..."
bash /tmp/setup_desktop.sh
success "Desktop setup complete."

POD_PID=$(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | head -1)
[[ -n "$POD_PID" ]] || { error "Pod PID not found. Desktop setup may have failed."; exit 1; }
info "Pod PID: ${POD_PID}"

# Write persistent env vars into pod so every terminal session gets them automatically
nsenter -t "${POD_PID}" -m -- bash -c "
mkdir -p ${TMPDIR_OVERRIDE}
cat > /etc/profile.d/agh-paths.sh << 'ENVEOF'
# AGH Creative Suite — paths and environment
export TMPDIR=${TMPDIR_OVERRIDE}
export AGH_MODELS=${MODELS_DIR}
export AGH_DATA=${DATA_DIR}
ENVEOF
chmod +x /etc/profile.d/agh-paths.sh
"
success "Pod environment configured (TMPDIR=${TMPDIR_OVERRIDE})."

# ── Phase 3: Always-on tools ──────────────────────────────────────────────────
step "Phase 3/5: Installing always-on creative tools"

info "Installing GIMP, Krita, Kdenlive, Audacity, Inkscape, Chrome..."
nsenter -t "${POD_PID}" -m -- bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
  gimp krita kdenlive audacity inkscape \
  python3-pip python3-venv git curl wget \
  2>/dev/null

# Chrome
wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
dpkg -i /tmp/chrome.deb 2>/dev/null || apt-get install -f -y -q
# Add --no-sandbox flag (required inside pod/container environment)
sed -i 's|Exec=/usr/bin/google-chrome-stable|Exec=/usr/bin/google-chrome-stable --no-sandbox|g' \
  /usr/share/applications/google-chrome.desktop 2>/dev/null || true
rm -f /tmp/chrome.deb
" && success "Core creative tools + Chrome installed." || warn "Some core tools failed."

info "Installing ComfyUI (AI workflow hub on port 8188)..."
nsenter -t "${POD_PID}" -m -- bash -c "
python3 -m venv /opt/comfyui-env
source /opt/comfyui-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet huggingface_hub
git clone https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI 2>/dev/null || \
  (cd /opt/ComfyUI && git pull)
pip install --quiet -r /opt/ComfyUI/requirements.txt
mkdir -p /opt/ComfyUI/models/{checkpoints,loras,vae,clip,unet,controlnet,upscale_models}
mkdir -p /opt/ComfyUI/user/default/workflows

# Pre-built workflow: Wan2.1 text-to-video
cat > '/opt/ComfyUI/user/default/workflows/wan21_t2v.json' << 'WFEOF'
{"last_node_id":5,"last_link_id":4,"nodes":[{"id":1,"type":"CLIPTextEncode","pos":[200,200],"size":{"0":400,"1":100},"flags":{},"order":0,"mode":0,"outputs":[{"name":"CONDITIONING","type":"CONDITIONING","links":[1]}],"properties":{},"widgets_values":["A cinematic timelapse of a futuristic city at golden hour. Flying vehicles streak across glowing skyscrapers. Ultra detailed, photorealistic, 4K quality."]},{"id":2,"type":"EmptyLatentImage","pos":[200,350],"size":{"0":300,"1":100},"flags":{},"order":1,"mode":0,"outputs":[{"name":"LATENT","type":"LATENT","links":[2]}],"properties":{},"widgets_values":[1280,720,1]},{"id":3,"type":"KSampler","pos":[650,200],"size":{"0":350,"1":300},"flags":{},"order":3,"mode":0,"inputs":[{"name":"model","type":"MODEL","link":null},{"name":"positive","type":"CONDITIONING","link":1},{"name":"negative","type":"CONDITIONING","link":null},{"name":"latent_image","type":"LATENT","link":2}],"outputs":[{"name":"LATENT","type":"LATENT","links":[3]}],"properties":{},"widgets_values":[42,"euler","normal",7,50]},{"id":4,"type":"VAEDecode","pos":[1050,200],"size":{"0":200,"1":100},"flags":{},"order":4,"mode":0,"inputs":[{"name":"samples","type":"LATENT","link":3},{"name":"vae","type":"VAE","link":null}],"outputs":[{"name":"IMAGE","type":"IMAGE","links":[4]}],"properties":{}},{"id":5,"type":"SaveImage","pos":[1300,200],"size":{"0":200,"1":100},"flags":{},"order":5,"mode":0,"inputs":[{"name":"images","type":"IMAGE","link":4}],"properties":{},"widgets_values":["wan21_output"]}],"links":[[1,1,0,3,1,"CONDITIONING"],[2,2,0,3,3,"LATENT"],[3,3,0,4,0,"LATENT"],[4,4,0,5,0,"IMAGE"]],"groups":[],"config":{},"extra":{},"version":0.4}
WFEOF
" && success "ComfyUI installed at /opt/ComfyUI." || warn "ComfyUI install failed."

info "Installing Fooocus (Midjourney-style image UI on port 7865)..."
nsenter -t "${POD_PID}" -m -- bash -c "
git clone https://github.com/lllyasviel/Fooocus /opt/Fooocus 2>/dev/null || \
  (cd /opt/Fooocus && git pull)
python3 -m venv /opt/fooocus-env
source /opt/fooocus-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet -r /opt/Fooocus/requirements_versions.txt
mkdir -p ${MODELS_DIR}/fooocus
# Point Fooocus model dir to data disk
sed -i 's|path_checkpoints.*|path_checkpoints = \"${MODELS_DIR}/fooocus/checkpoints\"|' \
  /opt/Fooocus/fooocus/config.py 2>/dev/null || true
" && success "Fooocus installed on port 7865." || warn "Fooocus install failed."

# ── Phase 4: Selected apps ────────────────────────────────────────────────────
step "Phase 4/5: Installing selected apps"

if [[ -z "$SELECTED_APPS" ]]; then
  info "No additional apps selected. Skipping."
else
  info "Installing: ${SELECTED_APPS}"
  for app in $SELECTED_APPS; do
    case "$app" in
      flux)     install_flux     ;;
      a1111)    install_a1111    ;;
      hunyuan)  install_hunyuan  ;;
      wan21)    install_wan21    ;;
      ltx)      install_ltx      ;;
      cogvideo) install_cogvideo ;;
      esrgan)   install_esrgan   ;;
      musicgen) install_musicgen ;;
      bark)     install_bark     ;;
      devtools) install_devtools ;;
      *)        warn "Unknown app: ${app}" ;;
    esac
  done
fi

# ── Write CLI wrapper scripts ─────────────────────────────────────────────────
# Users can run these from any terminal without knowing paths or venvs.
nsenter -t "${POD_PID}" -m -- bash -c "
mkdir -p /usr/local/bin

# wan21-generate \"prompt text\" [output.mp4]
cat > /usr/local/bin/wan21-generate << 'WEOF'
#!/usr/bin/env bash
PROMPT=\"\${1:-A cinematic scene, 4K quality}\"
OUTPUT=\"\${2:-${DATA_DIR}/output-\$(date +%s).mp4}\"
export TMPDIR=${TMPDIR_OVERRIDE}
source /opt/wan21-env/bin/activate
cd /opt/Wan2.1
exec python generate.py --task t2v-14B --size 1280*720 \
  --ckpt_dir ${MODELS_DIR}/wan21 \
  --sample_steps 50 --sample_guide_scale 6.0 \
  --prompt \"\$PROMPT\" --save_file \"\$OUTPUT\"
WEOF
chmod +x /usr/local/bin/wan21-generate

# whisperx-run audio_file
cat > /usr/local/bin/whisperx-run << 'WEOF'
#!/usr/bin/env bash
export TMPDIR=${TMPDIR_OVERRIDE}
source /opt/whisperx-env/bin/activate
exec whisperx \"\$@\"
WEOF
chmod +x /usr/local/bin/whisperx-run

# musicgen-generate \"prompt\" [duration_secs]
cat > /usr/local/bin/musicgen-generate << 'WEOF'
#!/usr/bin/env bash
PROMPT=\"\${1:-epic cinematic music}\"
DURATION=\"\${2:-30}\"
OUTPUT=\"\${3:-${DATA_DIR}/music-\$(date +%s).wav}\"
export TMPDIR=${TMPDIR_OVERRIDE}
source /opt/audio-env/bin/activate
python -c \"
from audiocraft.models import MusicGen
import torchaudio, sys
m = MusicGen.get_pretrained('melody')
m.set_generation_params(duration=int('${DURATION}'))
audio = m.generate(['${PROMPT}'])[0].cpu()
torchaudio.save('${OUTPUT}', audio, 32000)
print('Saved:', '${OUTPUT}')
\"
WEOF
chmod +x /usr/local/bin/musicgen-generate
" && success "CLI wrapper scripts installed." || warn "Wrapper script install failed."

# ── Phase 5: Start AI services ───────────────────────────────────────────────
step "Phase 5/5: Starting services"

# Track which services are running (for portal + tunnels)
declare -A SERVICE_PORTS
declare -A SERVICE_NAMES

# ComfyUI on port 8188
if [[ -d /opt/ComfyUI ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/comfyui-env/bin/activate
cd /opt/ComfyUI
TMPDIR=${TMPDIR_OVERRIDE} nohup python main.py --listen 0.0.0.0 --port 8188 --cuda-device 0 \
  > ${DATA_DIR}/comfyui.log 2>&1 &
" && success "ComfyUI starting on port 8188." || warn "ComfyUI start failed."
  SERVICE_PORTS[comfyui]=8188
  SERVICE_NAMES[comfyui]="ComfyUI — Advanced AI Workflows"
fi

# Fooocus on port 7865 (always installed)
if [[ -d /opt/Fooocus ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/fooocus-env/bin/activate
cd /opt/Fooocus
TMPDIR=${TMPDIR_OVERRIDE} nohup python launch.py --listen --port 7865 \
  > ${DATA_DIR}/fooocus.log 2>&1 &
" && success "Fooocus starting on port 7865." || warn "Fooocus start failed."
  SERVICE_PORTS[fooocus]=7865
  SERVICE_NAMES[fooocus]="Fooocus — Midjourney-Style Image Generator"
fi

# Wan2.1 Gradio UI on port 7870
if [[ -d /opt/Wan2.1 ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/wan21-env/bin/activate
cd /opt/Wan2.1
TMPDIR=${TMPDIR_OVERRIDE} nohup python gradio_app.py \
  > ${DATA_DIR}/wan21-gradio.log 2>&1 &
" && success "Wan2.1 Gradio UI starting on port 7870." || warn "Wan2.1 Gradio start failed."
  SERVICE_PORTS[wan21]=7870
  SERVICE_NAMES[wan21]="Wan2.1 — AI Video Generator (No Time Limits)"
fi

# A1111 on port 7860
if [[ -d /opt/stable-diffusion-webui ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/a1111-env/bin/activate
cd /opt/stable-diffusion-webui
TMPDIR=${TMPDIR_OVERRIDE} nohup python launch.py --listen --port 7860 --xformers --no-half-vae \
  > ${DATA_DIR}/a1111.log 2>&1 &
" && success "Stable Diffusion starting on port 7860." || warn "A1111 start failed."
  SERVICE_PORTS[a1111]=7860
  SERVICE_NAMES[a1111]="Stable Diffusion WebUI (A1111)"
fi

# JupyterLab + VS Code
if echo "$SELECTED_APPS" | grep -q "devtools"; then
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/jupyter-env/bin/activate
TMPDIR=${TMPDIR_OVERRIDE} nohup jupyter lab --ip=0.0.0.0 --port=8888 --no-browser \
  --NotebookApp.token='' --NotebookApp.password='' \
  > ${DATA_DIR}/jupyter.log 2>&1 &
" && success "JupyterLab starting on port 8888." || warn "JupyterLab start failed."
  SERVICE_PORTS[jupyter]=8888
  SERVICE_NAMES[jupyter]="JupyterLab"

  nohup code-server --bind-addr 0.0.0.0:8080 --auth none \
    > /tmp/code-server.log 2>&1 &
  success "VS Code starting on port 8080."
  SERVICE_PORTS[vscode]=8080
  SERVICE_NAMES[vscode]="VS Code"
fi

# ── Build portal page ─────────────────────────────────────────────────────────
# Served inside the pod on port 9080. Chrome opens it as homepage.
# Contains clickable links to every service — no SSH tunnel ever needed.

PORTAL_ROWS=""
PORTAL_ROWS+="<tr><td>🖥️</td><td><strong>XFCE Desktop</strong></td><td><a href='http://localhost:6080/vnc.html' target='_blank'>http://localhost:6080/vnc.html</a></td><td>Full Linux desktop</td></tr>"
[[ -n "${SERVICE_PORTS[fooocus]:-}" ]]  && PORTAL_ROWS+="<tr><td>🎨</td><td><strong>Fooocus</strong></td><td><a href='http://localhost:${SERVICE_PORTS[fooocus]}' target='_blank'>http://localhost:${SERVICE_PORTS[fooocus]}</a></td><td>Midjourney-style image generation</td></tr>"
[[ -n "${SERVICE_PORTS[wan21]:-}" ]]    && PORTAL_ROWS+="<tr><td>🎬</td><td><strong>Wan2.1 Video</strong></td><td><a href='http://localhost:${SERVICE_PORTS[wan21]}' target='_blank'>http://localhost:${SERVICE_PORTS[wan21]}</a></td><td>AI video — no time limits</td></tr>"
[[ -n "${SERVICE_PORTS[comfyui]:-}" ]]  && PORTAL_ROWS+="<tr><td>⚙️</td><td><strong>ComfyUI</strong></td><td><a href='http://localhost:${SERVICE_PORTS[comfyui]}' target='_blank'>http://localhost:${SERVICE_PORTS[comfyui]}</a></td><td>Advanced AI workflow editor</td></tr>"
[[ -n "${SERVICE_PORTS[a1111]:-}" ]]    && PORTAL_ROWS+="<tr><td>🖼️</td><td><strong>Stable Diffusion</strong></td><td><a href='http://localhost:${SERVICE_PORTS[a1111]}' target='_blank'>http://localhost:${SERVICE_PORTS[a1111]}</a></td><td>Full SD ecosystem</td></tr>"
[[ -n "${SERVICE_PORTS[jupyter]:-}" ]]  && PORTAL_ROWS+="<tr><td>📓</td><td><strong>JupyterLab</strong></td><td><a href='http://localhost:${SERVICE_PORTS[jupyter]}' target='_blank'>http://localhost:${SERVICE_PORTS[jupyter]}</a></td><td>Python notebooks</td></tr>"
[[ -n "${SERVICE_PORTS[vscode]:-}" ]]   && PORTAL_ROWS+="<tr><td>💻</td><td><strong>VS Code</strong></td><td><a href='http://localhost:${SERVICE_PORTS[vscode]}' target='_blank'>http://localhost:${SERVICE_PORTS[vscode]}</a></td><td>Code editor</td></tr>"

nsenter -t "${POD_PID}" -m -- bash -c "
mkdir -p /opt/agh-portal
cat > /opt/agh-portal/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
<meta charset=utf-8>
<title>AGH Creative Suite</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #0d1117; color: #e6edf3; margin: 0; padding: 40px; }
  h1   { color: #58a6ff; margin-bottom: 4px; }
  p    { color: #8b949e; margin-top: 0; margin-bottom: 32px; }
  table { border-collapse: collapse; width: 100%; max-width: 800px; }
  th   { text-align: left; padding: 10px 16px; border-bottom: 1px solid #30363d;
         color: #8b949e; font-weight: 500; font-size: 13px; text-transform: uppercase; }
  td   { padding: 14px 16px; border-bottom: 1px solid #21262d; }
  td:first-child { font-size: 22px; width: 36px; }
  a    { color: #58a6ff; text-decoration: none; font-family: monospace; font-size: 14px; }
  a:hover { text-decoration: underline; }
  td:last-child { color: #8b949e; font-size: 13px; }
  tr:hover td { background: #161b22; }
  .badge { display:inline-block; background:#238636; color:#fff;
           font-size:11px; padding:2px 8px; border-radius:12px; margin-left:8px; }
</style>
</head>
<body>
<h1>AGH Creative Suite</h1>
<p>GPU: ${GPU_NAME} &nbsp;|&nbsp; All services running below — click to open</p>
<table>
<tr><th></th><th>Service</th><th>URL</th><th>Description</th></tr>
${PORTAL_ROWS}
</table>
<p style='margin-top:32px;font-size:12px;'>
  Open this page anytime: <code>http://localhost:9080</code><br>
  Data directory: <code>${DATA_DIR}</code>
</p>
</body>
</html>
HTMLEOF

# Serve portal on port 9080
nohup python3 -m http.server 9080 --directory /opt/agh-portal \
  > /tmp/portal.log 2>&1 &

# Set Chrome homepage to portal
mkdir -p /root/.config/google-chrome/Default
cat > /root/.config/google-chrome/Default/Preferences << 'PREFEOF'
{\"browser\":{\"show_home_button\":true},\"homepage\":\"http://localhost:9080\",\"homepage_is_newtabpage\":false,\"session\":{\"restore_on_startup\":4,\"startup_urls\":[\"http://localhost:9080\"]}}
PREFEOF

# Desktop shortcut for portal
mkdir -p /root/Desktop
cat > /root/Desktop/AGH-Studio.desktop << 'DESKEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=AGH Creative Studio
Comment=Open AI tools portal
Exec=google-chrome-stable --no-sandbox http://localhost:9080
Icon=applications-multimedia
Terminal=false
Categories=Graphics;Video;
DESKEOF
chmod +x /root/Desktop/AGH-Studio.desktop
" && success "Portal ready on port 9080. Chrome homepage set." || warn "Portal setup failed."

# ── Cloudflare tunnels — one per service (no SSH needed for external access) ──
info "Starting cloudflare tunnels for external access (no SSH needed)..."
pkill cloudflared 2>/dev/null || true
sleep 1

declare -A TUNNEL_URLS

start_tunnel() {
  local name="$1" port="$2" logfile="/tmp/cf-tunnel-${name}.log"
  cloudflared tunnel --url "http://localhost:${port}" > "${logfile}" 2>&1 &
  # Wait up to 30s for URL
  for i in $(seq 1 30); do
    local url
    url=$(grep -o 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' "${logfile}" 2>/dev/null | head -1 || true)
    if [[ -n "$url" ]]; then
      TUNNEL_URLS[$name]="$url"
      return 0
    fi
    sleep 1
  done
  warn "Tunnel for ${name} timed out."
}

# Always tunnel desktop + portal
start_tunnel "portal"  9080
start_tunnel "desktop" 6080

# Tunnel each running service
[[ -n "${SERVICE_PORTS[fooocus]:-}" ]]  && start_tunnel "fooocus"  "${SERVICE_PORTS[fooocus]}"
[[ -n "${SERVICE_PORTS[wan21]:-}" ]]    && start_tunnel "wan21"    "${SERVICE_PORTS[wan21]}"
[[ -n "${SERVICE_PORTS[comfyui]:-}" ]]  && start_tunnel "comfyui"  "${SERVICE_PORTS[comfyui]}"
[[ -n "${SERVICE_PORTS[a1111]:-}" ]]    && start_tunnel "a1111"    "${SERVICE_PORTS[a1111]}"

# Inject public URLs into portal page
PORTAL_PUBLIC=""
for svc in portal desktop fooocus wan21 comfyui a1111 jupyter vscode; do
  [[ -n "${TUNNEL_URLS[$svc]:-}" ]] && \
    PORTAL_PUBLIC+="<li><strong>${svc}</strong>: <a href='${TUNNEL_URLS[$svc]}'>${TUNNEL_URLS[$svc]}</a></li>"
done

if [[ -n "$PORTAL_PUBLIC" ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
sed -i 's|</body>|<hr><h3 style=\"color:#58a6ff\">Public URLs (shareable)</h3><ul style=\"font-family:monospace;line-height:2\">${PORTAL_PUBLIC}</ul></body>|' /opt/agh-portal/index.html
"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "unknown")

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║              AGH Creative Suite Ready!                       ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}GPU:${NC}   ${GPU_NAME}"
echo -e "${BOLD}Apps:${NC}  ${SELECTED_APPS:-core tools only}"
echo ""
echo -e "${BOLD}${GREEN}── Inside the desktop (no SSH needed) ───────────────────────${NC}"
echo -e "  Open Chrome in the desktop — it opens the portal automatically."
echo -e "  Or visit:  ${CYAN}http://localhost:9080${NC}"
echo ""
echo -e "${BOLD}${GREEN}── Public URLs (shareable, no SSH needed) ───────────────────${NC}"
[[ -n "${TUNNEL_URLS[portal]:-}" ]]   && echo -e "  ${GREEN}${BOLD}Portal:${NC}            ${TUNNEL_URLS[portal]}"
[[ -n "${TUNNEL_URLS[desktop]:-}" ]]  && echo -e "  ${GREEN}Desktop:${NC}           ${TUNNEL_URLS[desktop]}/vnc.html  ${YELLOW}(password protected)${NC}"
[[ -n "${TUNNEL_URLS[fooocus]:-}" ]]  && echo -e "  ${GREEN}Fooocus:${NC}           ${TUNNEL_URLS[fooocus]}"
[[ -n "${TUNNEL_URLS[wan21]:-}" ]]    && echo -e "  ${GREEN}Wan2.1 Video:${NC}      ${TUNNEL_URLS[wan21]}"
[[ -n "${TUNNEL_URLS[comfyui]:-}" ]]  && echo -e "  ${GREEN}ComfyUI:${NC}           ${TUNNEL_URLS[comfyui]}"
[[ -n "${TUNNEL_URLS[a1111]:-}" ]]    && echo -e "  ${GREEN}Stable Diffusion:${NC}  ${TUNNEL_URLS[a1111]}"
echo ""
echo -e "  ${YELLOW}Note:${NC} Public URLs reset on VM reboot. Regenerate:"
echo -e "  ${CYAN}cloudflared tunnel --url http://localhost:9080${NC}"
echo ""
echo -e "${BOLD}${GREEN}── SSH tunnel (optional, for private access) ─────────────────${NC}"
echo -e "  ${CYAN}ssh -L 9080:127.0.0.1:9080 shadeform@${SERVER_IP}${NC}"
echo -e "  Then open: http://localhost:9080"
echo ""
