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

MODELS_DIR="/opt/models"
APPS_DIR="/opt/apps"
LOGS_DIR="/tmp/creative-suite-logs"
SELECTED_APPS=""
POD_PID=""

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

mkdir -p "${MODELS_DIR}" "${APPS_DIR}" "${LOGS_DIR}"

banner
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "not detected")
info "Host: $(hostname)  |  GPU: ${GPU_NAME}  |  Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

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
huggingface-cli download black-forest-labs/FLUX.1-dev \
  flux1-dev.safetensors \
  --local-dir /opt/ComfyUI/models/unet/ \
  --local-dir-use-symlinks False
huggingface-cli download comfyanonymous/flux_text_encoders \
  clip_l.safetensors t5xxl_fp8_e4m3fn.safetensors \
  --local-dir /opt/ComfyUI/models/clip/ \
  --local-dir-use-symlinks False
huggingface-cli download black-forest-labs/FLUX.1-dev \
  ae.safetensors \
  --local-dir /opt/ComfyUI/models/vae/ \
  --local-dir-use-symlinks False
" && success "FLUX model downloaded." || warn "FLUX download failed — retry: huggingface-cli download black-forest-labs/FLUX.1-dev"
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
huggingface-cli download runwayml/stable-diffusion-v1-5 \
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
mkdir -p /opt/models/hunyuan
huggingface-cli download tencent/HunyuanVideo \
  --local-dir /opt/models/hunyuan \
  --local-dir-use-symlinks False
" && success "HunyuanVideo installed." || warn "HunyuanVideo install failed."
}

install_wan21() {
  info "Installing Wan2.1 (~14GB)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
pip install --quiet diffusers transformers accelerate
git clone https://github.com/Wan-Video/Wan2.1 /opt/Wan2.1 2>/dev/null || \
  (cd /opt/Wan2.1 && git pull)
python3 -m venv /opt/wan21-env
source /opt/wan21-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet -r /opt/Wan2.1/requirements.txt
mkdir -p /opt/models/wan21
huggingface-cli download Wan-AI/Wan2.1-T2V-14B \
  --local-dir /opt/models/wan21 \
  --local-dir-use-symlinks False
" && success "Wan2.1 installed." || warn "Wan2.1 install failed."
}

install_ltx() {
  info "Installing LTX-Video (~8GB — fast generation)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
python3 -m venv /opt/ltx-env
source /opt/ltx-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet 'ltx-video' diffusers transformers accelerate
mkdir -p /opt/models/ltx
huggingface-cli download Lightricks/LTX-Video \
  --local-dir /opt/models/ltx \
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
mkdir -p /opt/models/cogvideo
huggingface-cli download THUDM/CogVideoX-5b \
  --local-dir /opt/models/cogvideo \
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
mkdir -p /opt/models/realesrgan
wget -qO /opt/models/realesrgan/RealESRGAN_x4plus.pth \
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

# ── Phase 3: Always-on tools ──────────────────────────────────────────────────
step "Phase 3/5: Installing always-on creative tools"

info "Installing GIMP, Krita, Kdenlive, Audacity, Inkscape..."
nsenter -t "${POD_PID}" -m -- bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
  gimp krita kdenlive audacity inkscape \
  python3-pip python3-venv git curl wget \
  2>/dev/null
" && success "Core creative tools installed." || warn "Some core tools failed."

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
" && success "ComfyUI installed at /opt/ComfyUI." || warn "ComfyUI install failed."

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

# ── Phase 5: Start services ───────────────────────────────────────────────────
step "Phase 5/5: Starting services"

# ComfyUI on port 8188
if [[ -d /opt/ComfyUI ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/comfyui-env/bin/activate
cd /opt/ComfyUI
nohup python main.py --listen 0.0.0.0 --port 8188 --cuda-device 0 \
  > /tmp/comfyui.log 2>&1 &
" && success "ComfyUI starting on port 8188." || warn "ComfyUI start failed."
fi

# A1111 on port 7860
if [[ -d /opt/stable-diffusion-webui ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/a1111-env/bin/activate
cd /opt/stable-diffusion-webui
nohup python launch.py --listen --port 7860 --xformers --no-half-vae \
  > /tmp/a1111.log 2>&1 &
" && success "Stable Diffusion starting on port 7860." || warn "A1111 start failed."
fi

# JupyterLab + VS Code
if echo "$SELECTED_APPS" | grep -q "devtools"; then
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/jupyter-env/bin/activate
nohup jupyter lab --ip=0.0.0.0 --port=8888 --no-browser \
  --NotebookApp.token='' --NotebookApp.password='' \
  > /tmp/jupyter.log 2>&1 &
" && success "JupyterLab starting on port 8888." || warn "JupyterLab start failed."

  nohup code-server --bind-addr 0.0.0.0:8080 --auth none \
    > /tmp/code-server.log 2>&1 &
  success "VS Code starting on port 8080."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
PUBLIC_URL=$(grep -o 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' /tmp/cloudflared-tunnel.log 2>/dev/null | head -1 || true)
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "unknown")

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║           AGH Creative Suite Ready!                      ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}GPU:${NC}   ${GPU_NAME}"
echo -e "${BOLD}Apps:${NC}  ${SELECTED_APPS:-core tools only}"
echo ""
echo -e "${BOLD}Access:${NC}"
[[ -n "$PUBLIC_URL" ]] && \
  echo -e "  ${GREEN}${BOLD}Public URL:${NC}  ${PUBLIC_URL}/vnc.html"
echo -e "  ${YELLOW}Password:${NC}    Use the password you set during setup"
echo ""
echo -e "${BOLD}SSH tunnel (all services):${NC}"
echo -e "  ${CYAN}ssh -L 6080:127.0.0.1:6080 -L 8188:127.0.0.1:8188 -L 7860:127.0.0.1:7860 -L 8888:127.0.0.1:8888 shadeform@${SERVER_IP}${NC}"
echo ""
echo -e "${BOLD}Services:${NC}"
echo -e "  ${GREEN}•${NC} Desktop:           http://localhost:6080/vnc.html"
[[ -d /opt/ComfyUI ]] && \
  echo -e "  ${GREEN}•${NC} ComfyUI:           http://localhost:8188  (AI image + video)"
[[ -d /opt/stable-diffusion-webui ]] && \
  echo -e "  ${GREEN}•${NC} Stable Diffusion:  http://localhost:7860"
echo "$SELECTED_APPS" | grep -q "devtools" 2>/dev/null && \
  echo -e "  ${GREEN}•${NC} JupyterLab:        http://localhost:8888" && \
  echo -e "  ${GREEN}•${NC} VS Code:            http://localhost:8080" || true
echo ""
echo -e "${BOLD}Quick start (run in desktop terminal):${NC}"
echo -e "  ${CYAN}# Transcribe audio${NC}"
echo -e "  source /opt/whisperx-env/bin/activate && whisperx audio.mp3 --model base"
echo ""
if echo "$SELECTED_APPS" | grep -q "musicgen" 2>/dev/null; then
  echo -e "  ${CYAN}# Generate music${NC}"
  echo -e "  source /opt/audio-env/bin/activate"
  echo -e "  python -c \"from audiocraft.models import MusicGen; m=MusicGen.get_pretrained('melody'); m.set_generation_params(duration=30); import torchaudio; torchaudio.save('/tmp/music.wav', m.generate(['epic cinematic'])[0].cpu(), 32000)\""
  echo ""
fi
if echo "$SELECTED_APPS" | grep -q "wan21" 2>/dev/null; then
  echo -e "  ${CYAN}# Generate video (Wan2.1)${NC}"
  echo -e "  source /opt/wan21-env/bin/activate && cd /opt/Wan2.1"
  echo ""
fi
echo -e "  ${YELLOW}Note:${NC} Public URL is temporary — regenerate: cloudflared tunnel --url http://localhost:6080"
echo ""
