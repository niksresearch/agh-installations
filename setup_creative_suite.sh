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
declare -A SERVICE_PORTS=()
declare -A SERVICE_NAMES=()
declare -A TUNNEL_URLS=()

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

# ── Non-interactive mode ──────────────────────────────────────────────────────
# Unattended (Shadeform startup script / cloud-init) when BUNDLE env var is set.
# Required env for unattended: BUNDLE (1-3) and VNC_PASS. HF_TOKEN optional.
NONINTERACTIVE=0
[[ -n "${BUNDLE:-}" ]] && NONINTERACTIVE=1

# ── HuggingFace account setup ─────────────────────────────────────────────────
HF_TOKEN_FILE="/root/.hf_token"
FLUX_REPO=""

if [[ -z "${HF_TOKEN:-}" ]] && [[ -f "${HF_TOKEN_FILE}" ]]; then
  HF_TOKEN=$(cat "${HF_TOKEN_FILE}")
  success "HuggingFace token loaded from saved file."
fi

# Save env-provided token to file for reuse
if [[ -n "${HF_TOKEN:-}" ]] && [[ ! -f "${HF_TOKEN_FILE}" ]]; then
  echo "${HF_TOKEN}" > "${HF_TOKEN_FILE}"; chmod 600 "${HF_TOKEN_FILE}"
fi

if [[ -z "${HF_TOKEN:-}" ]] && [[ "${NONINTERACTIVE}" == "1" ]]; then
  warn "No HF_TOKEN provided (unattended) — FLUX skipped, Stable Diffusion used for images."
elif [[ -z "${HF_TOKEN:-}" ]]; then
  echo ""
  echo -e "${BOLD}HuggingFace Account Setup${NC}"
  echo -e "${CYAN}HuggingFace is used to download AI models (FLUX image generation etc.)${NC}"
  echo ""
  echo -e "  ${CYAN}[1]${NC} ${BOLD}I have a HuggingFace token${NC}  — adds FLUX (best image quality)"
  echo -e "         Free account works. Get token: https://huggingface.co/settings/tokens"
  echo ""
  echo -e "  ${CYAN}[2]${NC} ${BOLD}Skip${NC}  — image generation still works (Stable Diffusion, no token)"
  echo -e "         FLUX adds higher quality later — just re-run this script with a token"
  echo ""
  read -rp "$(echo -e "${BOLD}Choose [1-2]:${NC} ")" hf_choice

  case "${hf_choice}" in
    1)
      echo ""
      echo -e "${CYAN}Steps if you haven't already:${NC}"
      echo -e "  1. Sign up free at https://huggingface.co"
      echo -e "  2. Accept FLUX license: https://huggingface.co/black-forest-labs/FLUX.1-schnell"
      echo -e "  3. Get token: https://huggingface.co/settings/tokens → New token → Read"
      echo ""
      read -rsp "$(echo -e "${BOLD}Paste token:${NC} ")" HF_TOKEN
      echo ""
      if [[ -n "${HF_TOKEN}" ]]; then
        echo "${HF_TOKEN}" > "${HF_TOKEN_FILE}"
        chmod 600 "${HF_TOKEN_FILE}"
        success "Token saved. Will be reused on future runs."
      else
        warn "No token entered. FLUX will be skipped."
      fi
      ;;
    *)
      warn "Skipping HuggingFace. FLUX image models will not be installed."
      warn "Re-run this script anytime to add them."
      ;;
  esac
fi
export HF_TOKEN="${HF_TOKEN:-}"

# ── Password prompt ───────────────────────────────────────────────────────────
if [[ -z "${VNC_PASS:-}" ]] && [[ "${NONINTERACTIVE}" == "1" ]]; then
  error "Unattended mode (BUNDLE set) requires VNC_PASS env var (min 6 chars)."
  exit 1
fi
if [[ -n "${VNC_PASS:-}" ]]; then
  [[ ${#VNC_PASS} -ge 6 ]] || { error "VNC_PASS must be at least 6 characters."; exit 1; }
  success "Desktop password taken from environment."
else
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
fi
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
# Unattended: set BUNDLE=1|2|3 env var to skip the menu.
pick_bundle() {
  case "$1" in
    1) SELECTED_APPS="flux wan21 esrgan" ;;
    2) SELECTED_APPS="flux wan21 hunyuan musicgen bark esrgan" ;;
    3) SELECTED_APPS="flux a1111 hunyuan wan21 ltx cogvideo esrgan musicgen bark devtools" ;;
    *) return 1 ;;
  esac
}

if [[ -n "${BUNDLE:-}" ]]; then
  pick_bundle "${BUNDLE}" || { error "Invalid BUNDLE='${BUNDLE}' (use 1, 2, or 3)."; exit 1; }
  success "Bundle ${BUNDLE} selected from environment."
else
  echo ""
  echo -e "${BOLD}Always installed:${NC} GIMP, Krita, Kdenlive, Audacity, Inkscape, ComfyUI, FFmpeg, Blender, WhisperX, MusicGen"
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
      1|2|3) pick_bundle "$bundle_choice"; break ;;
      4) show_custom_menu; break ;;
      *) warn "Enter 1, 2, 3, or 4." ;;
    esac
  done
fi

info "Selected: ${SELECTED_APPS:-core tools only}"

# ── Install functions ─────────────────────────────────────────────────────────

install_flux() {
  # Both FLUX.1-dev and FLUX.1-schnell require HF account + license approval.
  # Accept at https://huggingface.co/black-forest-labs/FLUX.1-schnell
  # Then get token at https://huggingface.co/settings/tokens
  # Pass as: HF_TOKEN=hf_xxx sudo bash setup_creative_suite.sh
  # FLUX_VARIANT=dev for higher quality (gated, needs license); default schnell.
  if [[ "${FLUX_VARIANT:-schnell}" == "dev" ]]; then
    FLUX_REPO="black-forest-labs/FLUX.1-dev"
    FLUX_FILE="flux1-dev.safetensors"
  else
    FLUX_REPO="black-forest-labs/FLUX.1-schnell"
    FLUX_FILE="flux1-schnell.safetensors"
  fi
  info "Downloading FLUX model (${FLUX_REPO}, ~24GB)..."
  if [[ -z "${HF_TOKEN:-}" ]]; then
    warn "No HuggingFace token found. FLUX download will likely fail."
    warn "Re-run setup to enter your token."
    return 0
  fi

  local TOKEN_ARG=""
  [[ -n "${HF_TOKEN:-}" ]] && TOKEN_ARG="--token ${HF_TOKEN}"

  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/comfyui-env/bin/activate
hf download ${FLUX_REPO} \
  ${FLUX_FILE} \
  --local-dir ${MODELS_DIR}/comfyui/unet/ ${TOKEN_ARG}
hf download comfyanonymous/flux_text_encoders \
  clip_l.safetensors t5xxl_fp8_e4m3fn.safetensors \
  --local-dir ${MODELS_DIR}/comfyui/clip/ ${TOKEN_ARG}
hf download ${FLUX_REPO} \
  ae.safetensors \
  --local-dir ${MODELS_DIR}/comfyui/vae/ ${TOKEN_ARG}
" && success "FLUX model downloaded (${FLUX_REPO})." \
  || warn "FLUX download failed. Accept license at https://huggingface.co/${FLUX_REPO} then re-run with HF_TOKEN=hf_xxx"
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
# runwayml/stable-diffusion-v1-5 was deleted from HF — use the gateless Comfy-Org mirror
wget -q -O /opt/stable-diffusion-webui/models/Stable-diffusion/v1-5-pruned-emaonly.safetensors \
  https://huggingface.co/Comfy-Org/stable-diffusion-v1-5-archive/resolve/main/v1-5-pruned-emaonly-fp16.safetensors
" && success "A1111 installed." || warn "A1111 install failed."
}

# AGH Video Studio — installs LTX-Video, CogVideoX-5B and HunyuanVideo together via
# diffusers (clean, turnkey pipelines) into one shared venv, with a unified Gradio UI
# on port 7871. Replaces the old per-model installs that downloaded weights with no UI.
install_video_studio() {
  local models="$1"
  [[ -z "${models// /}" ]] && return 0
  info "Installing AGH Video Studio (diffusers UI, port 7871) for:${models}"

  # Map selected app names -> diffusers repo ids to prefetch into HF cache
  local PREFETCH=""
  for m in $models; do
    case "$m" in
      ltx)      PREFETCH="${PREFETCH} Lightricks/LTX-Video" ;;
      cogvideo) PREFETCH="${PREFETCH} THUDM/CogVideoX-5b" ;;
      hunyuan)  PREFETCH="${PREFETCH} hunyuanvideo-community/HunyuanVideo" ;;
    esac
  done

  # Unified Gradio app — written on host, base64-encoded, decoded inside pod
  cat > /tmp/agh_video_studio.py << 'PYEOF'
import gradio as gr, os, time, torch
from diffusers.utils import export_to_video

MODELS_DIR = os.environ.get("AGH_MODELS", "/opt/models")
TMPDIR_DIR = os.environ.get("TMPDIR", "/tmp")
os.environ.setdefault("HF_HOME", os.path.join(MODELS_DIR, "hf-cache"))
AVAILABLE = [m for m in os.environ.get("AGH_VIDEO_MODELS", "").split(",") if m]

_PIPES = {}

def load_pipe(model):
    if model in _PIPES:
        return _PIPES[model]
    if model == "LTX-Video":
        from diffusers import LTXPipeline
        pipe = LTXPipeline.from_pretrained("Lightricks/LTX-Video", torch_dtype=torch.bfloat16)
    elif model == "CogVideoX-5B":
        from diffusers import CogVideoXPipeline
        pipe = CogVideoXPipeline.from_pretrained("THUDM/CogVideoX-5b", torch_dtype=torch.bfloat16)
    elif model == "HunyuanVideo":
        from diffusers import HunyuanVideoPipeline, HunyuanVideoTransformer3DModel
        repo = "hunyuanvideo-community/HunyuanVideo"
        tr = HunyuanVideoTransformer3DModel.from_pretrained(repo, subfolder="transformer", torch_dtype=torch.bfloat16)
        pipe = HunyuanVideoPipeline.from_pretrained(repo, transformer=tr, torch_dtype=torch.float16)
    else:
        raise ValueError("Unknown model: " + str(model))
    # Stream layers GPU<->CPU + tile VAE so big models fit on a single card
    pipe.enable_model_cpu_offload()
    try:
        pipe.vae.enable_tiling()
    except Exception:
        pass
    _PIPES[model] = pipe
    return pipe

def generate(model, prompt, steps, frames, fps):
    if not model:
        return None, "Select a model first."
    if not prompt.strip():
        return None, "Enter a prompt."
    try:
        pipe = load_pipe(model)
    except Exception as e:
        return None, "Model load failed: " + str(e)[:600]
    kwargs = {"prompt": prompt, "num_inference_steps": int(steps)}
    if model == "LTX-Video":
        kwargs.update(width=768, height=512, num_frames=int(frames))
    elif model == "CogVideoX-5B":
        kwargs.update(num_frames=int(frames), guidance_scale=6.0)
    elif model == "HunyuanVideo":
        kwargs.update(height=320, width=512, num_frames=int(frames))
    try:
        result = pipe(**kwargs)
        video = result.frames[0]
    except Exception as e:
        return None, "Generation failed: " + str(e)[:600]
    out = os.path.join(TMPDIR_DIR, "video_%d.mp4" % int(time.time()))
    export_to_video(video, out, fps=int(fps))
    return out, "Done: " + model

with gr.Blocks(title="AGH Video Studio", theme=gr.themes.Soft()) as demo:
    gr.Markdown("# AGH Video Studio\nTop open video models — LTX-Video, CogVideoX, HunyuanVideo. No limits, no credits.")
    with gr.Row():
        with gr.Column(scale=2):
            model = gr.Dropdown(AVAILABLE, value=(AVAILABLE[0] if AVAILABLE else None), label="Model")
            prompt = gr.Textbox(label="Prompt", lines=4,
                placeholder="A cinematic timelapse of a futuristic city at golden hour...")
            with gr.Row():
                steps  = gr.Slider(10, 60, value=30, step=5, label="Steps")
                frames = gr.Slider(17, 161, value=49, step=8, label="Frames")
                fps    = gr.Slider(8, 30, value=16, step=1, label="FPS")
            btn = gr.Button("Generate Video", variant="primary", size="lg")
        with gr.Column(scale=2):
            video_out = gr.Video(label="Generated Video")
            status    = gr.Textbox(label="Status", interactive=False)
    btn.click(generate, inputs=[model, prompt, steps, frames, fps], outputs=[video_out, status])

demo.launch(server_name="0.0.0.0", server_port=7871, share=False)
PYEOF
  local VSTUDIO_B64
  VSTUDIO_B64=$(base64 -w0 /tmp/agh_video_studio.py)

  nsenter -t "${POD_PID}" -m -- bash -c "
python3 -m venv /opt/agh-video-env
source /opt/agh-video-env/bin/activate
pip install --quiet wheel setuptools
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet 'diffusers>=0.32.0' transformers accelerate sentencepiece imageio imageio-ffmpeg gradio
export HF_HOME=${MODELS_DIR}/hf-cache
mkdir -p \${HF_HOME}
for repo in ${PREFETCH}; do
  python -c \"from huggingface_hub import snapshot_download; snapshot_download('\$repo')\" 2>/dev/null \
    || echo \"[WARN] prefetch \$repo failed (will fetch on first use)\"
done
echo '${VSTUDIO_B64}' | base64 -d > /opt/agh_video_studio.py
" && success "AGH Video Studio installed (port 7871)." || warn "AGH Video Studio install failed."
}

install_wan21() {
  info "Installing Wan2.1 (~14GB)..."

  # Step A: clone, venv, pip, model download
  nsenter -t "${POD_PID}" -m -- bash -c "
git clone https://github.com/Wan-Video/Wan2.1 /opt/Wan2.1 2>/dev/null || \
  (cd /opt/Wan2.1 && git pull)
python3 -m venv /opt/wan21-env
source /opt/wan21-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet wheel setuptools
pip install --quiet -r /opt/Wan2.1/requirements.txt
pip install --quiet huggingface_hub
pip install flash-attn --no-build-isolation --quiet 2>/dev/null || \
  echo '[WARN] flash-attn compile failed — will patch to sdp fallback'
mkdir -p ${MODELS_DIR}/wan21
hf download Wan-AI/Wan2.1-T2V-14B \
  --local-dir ${MODELS_DIR}/wan21 \
" || { warn "Wan2.1 install failed."; return 1; }

  # Step B: patch attention.py — write on host, base64-encode, decode+run inside pod
  cat > /tmp/wan21_attn_patch.py << 'PYEOF'
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
  ATTN_B64=$(base64 -w0 /tmp/wan21_attn_patch.py)
  nsenter -t "${POD_PID}" -m -- bash -c "
echo '${ATTN_B64}' | base64 -d > /tmp/wan21_attn_patch.py
source /opt/wan21-env/bin/activate
python3 /tmp/wan21_attn_patch.py
"

  # Step C: write Gradio UI — write on host, base64-encode, decode inside pod
  cat > /tmp/wan21_gradio_app.py << 'PYEOF'
import gradio as gr, subprocess, os, time

MODELS_DIR = os.environ.get("AGH_MODELS", "/opt/models")
TMPDIR_DIR = os.environ.get("TMPDIR", "/tmp")

def generate_video(prompt, steps, guidance, width, height):
    ts = int(time.time())
    out = os.path.join(TMPDIR_DIR, f"wan21_{ts}.mp4")
    size = f"{int(width)}*{int(height)}"
    cmd = [
        "python", "generate.py",
        "--task", "t2v-14B",
        "--size", size,
        "--ckpt_dir", os.path.join(MODELS_DIR, "wan21"),
        "--sample_steps", str(int(steps)),
        "--sample_guide_scale", str(float(guidance)),
        "--prompt", prompt,
        "--save_file", out,
    ]
    env = os.environ.copy()
    env["TMPDIR"] = TMPDIR_DIR
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
PYEOF
  GRADIO_B64=$(base64 -w0 /tmp/wan21_gradio_app.py)
  nsenter -t "${POD_PID}" -m -- bash -c "
echo '${GRADIO_B64}' | base64 -d > /opt/Wan2.1/gradio_app.py
"
  success "Wan2.1 installed with Gradio UI on port 7870."
}

# LTX-Video, CogVideoX-5B and HunyuanVideo are installed together by
# install_video_studio() (diffusers + shared venv + unified Gradio UI on 7871).

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
  info "Installing MusicGen + Demucs (~5.5GB + model preload)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
export DEBIAN_FRONTEND=noninteractive
# PyAV (audiocraft dep) builds from source — needs ffmpeg dev libs + pkg-config
apt-get install -y --no-install-recommends \
  pkg-config libavformat-dev libavcodec-dev libavdevice-dev \
  libavutil-dev libavfilter-dev libswscale-dev libswresample-dev 2>/dev/null
python3 -m venv /opt/audio-env
source /opt/audio-env/bin/activate
pip install --quiet wheel setuptools
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet audiocraft
pip install --quiet demucs
# audiocraft pins torch 2.1 — force-compatible transformers + numpy (else T5 fails / numpy 2.x crash)
pip install --quiet 'numpy<2' 'transformers==4.40.0'
# Preload melody model so first generation is instant (cached to ${MODELS_DIR})
export HF_HOME=${MODELS_DIR}/hf-cache
python -c 'from audiocraft.models import MusicGen; MusicGen.get_pretrained(\"melody\"); print(\"MusicGen model cached\")' 2>/dev/null || true
" && success "MusicGen + Demucs installed (model preloaded)." || warn "Audio tools install failed."
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

info "Installing GIMP, Krita, Kdenlive, Audacity, Inkscape, Chrome, mpv, eog..."
nsenter -t "${POD_PID}" -m -- bash -c "
export DEBIAN_FRONTEND=noninteractive
# apt-get update first: on a fresh pod the package lists are often empty, so an
# install with no update silently fails and leaves wget/curl missing — which in turn
# broke chrome + checkpoint downloads. Update, then ensure wget/curl are really here.
apt-get update -y 2>/dev/null || true
apt-get install -y --no-install-recommends \
  gimp krita kdenlive audacity inkscape \
  mpv eog \
  python3-pip python3-venv git curl wget \
  2>/dev/null
command -v wget >/dev/null || echo '[WARN] wget still missing after apt install'

# Chrome
wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
dpkg -i /tmp/chrome.deb 2>/dev/null || apt-get install -f -y -q
sed -i 's|Exec=/usr/bin/google-chrome-stable|Exec=/usr/bin/google-chrome-stable --no-sandbox|g' \
  /usr/share/applications/google-chrome.desktop 2>/dev/null || true
rm -f /tmp/chrome.deb

# Desktop shortcuts for media viewers
mkdir -p /root/Desktop

cat > /root/Desktop/Video-Player.desktop << 'DEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Video Player (mpv)
Comment=Play AI-generated videos
Exec=bash -c 'mpv \$(zenity --file-selection --title=\"Open Video\" --file-filter=\"Videos | *.mp4 *.webm *.avi *.mkv\" 2>/dev/null) 2>/dev/null'
Icon=video-x-generic
Terminal=false
Categories=Video;Player;
DEOF
chmod +x /root/Desktop/Video-Player.desktop

cat > /root/Desktop/Image-Viewer.desktop << 'DEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Image Viewer (eog)
Comment=View AI-generated images
Exec=bash -c 'eog \$(zenity --file-selection --title=\"Open Image\" --file-filter=\"Images | *.png *.jpg *.jpeg *.webp\" 2>/dev/null) 2>/dev/null'
Icon=image-x-generic
Terminal=false
Categories=Graphics;Viewer;
DEOF
chmod +x /root/Desktop/Image-Viewer.desktop

cat > /root/Desktop/Browse-Outputs.desktop << 'DEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Browse AI Outputs
Comment=Open output folder in file manager
Exec=thunar /ephemeral
Icon=folder-pictures
Terminal=false
Categories=FileManager;
DEOF
chmod +x /root/Desktop/Browse-Outputs.desktop
" && success "Core creative tools + media viewers + desktop shortcuts installed." || warn "Some core tools failed."

info "Installing ComfyUI (AI workflow hub on port 8188)..."
nsenter -t "${POD_PID}" -m -- bash -c "
python3 -m venv /opt/comfyui-env
source /opt/comfyui-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install --quiet huggingface_hub
git clone https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI 2>/dev/null || \
  (cd /opt/ComfyUI && git pull)
pip install --quiet -r /opt/ComfyUI/requirements.txt
pip install --quiet gradio diffusers transformers accelerate
mkdir -p ${MODELS_DIR}/comfyui/{checkpoints,loras,vae,clip,unet,controlnet,upscale_models}
rm -rf /opt/ComfyUI/models
ln -sfn ${MODELS_DIR}/comfyui /opt/ComfyUI/models
mkdir -p /opt/ComfyUI/user/default/workflows
# Free image checkpoints (gateless mirrors — no token). Pulled via huggingface_hub
# (just pip-installed above) instead of wget: the pod image may not ship wget, which
# silently left the checkpoints/ dir empty and broke all ComfyUI image generation.
export CKPT_DIR=${MODELS_DIR}/comfyui/checkpoints
python - <<'PYEOF'
import os
from huggingface_hub import hf_hub_download
ckpt_dir = os.environ['CKPT_DIR']
os.makedirs(ckpt_dir, exist_ok=True)
# (repo, file-in-repo, final-name-on-disk)
jobs = [
    ('Comfy-Org/stable-diffusion-v1-5-archive', 'v1-5-pruned-emaonly-fp16.safetensors', 'v1-5-pruned-emaonly.safetensors'),
    ('stabilityai/stable-diffusion-xl-base-1.0', 'sd_xl_base_1.0.safetensors',          'sd_xl_base_1.0.safetensors'),
]
for repo, fname, dest in jobs:
    target = os.path.join(ckpt_dir, dest)
    if os.path.exists(target) and os.path.getsize(target) > 100_000_000:
        print('[OK] already present:', dest); continue
    try:
        p = hf_hub_download(repo_id=repo, filename=fname, local_dir=ckpt_dir)
        if os.path.abspath(p) != os.path.abspath(target):
            os.replace(p, target)
        print('[OK] downloaded:', dest, os.path.getsize(target))
    except Exception as e:
        print('[WARN] checkpoint download failed:', dest, e)
PYEOF
# Verify at least one checkpoint landed — fail loud instead of silently shipping an empty dir.
if ! ls ${MODELS_DIR}/comfyui/checkpoints/*.safetensors >/dev/null 2>&1; then
  echo '[ERROR] No ComfyUI checkpoint downloaded — image generation will not work.'
fi
# ComfyUI's built-in default graph is a working txt2img workflow that loads the
# checkpoints above — no custom workflow file needed (old placeholder was invalid).
" && success "ComfyUI installed at /opt/ComfyUI." || warn "ComfyUI install failed."

info "ComfyUI handles image generation on port 8188 — no separate image UI needed."

# MusicGen always installed (every bundle) — audio is a core creative capability
install_musicgen
# Avoid re-installing if a bundle also listed it
SELECTED_APPS="$(echo "$SELECTED_APPS" | sed 's/\bmusicgen\b//g' | tr -s ' ' | sed 's/^ //;s/ $//')"

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
      wan21)    install_wan21    ;;
      hunyuan|ltx|cogvideo) : ;;  # bundled into AGH Video Studio after the loop
      esrgan)   install_esrgan   ;;
      musicgen) install_musicgen ;;
      bark)     install_bark     ;;
      devtools) install_devtools ;;
      *)        warn "Unknown app: ${app}" ;;
    esac
  done
fi

# Install LTX / CogVideoX / Hunyuan together as AGH Video Studio (unified diffusers UI)
VIDEO_EXTRAS=""
for m in ltx cogvideo hunyuan; do
  echo " ${SELECTED_APPS} " | grep -q " ${m} " && VIDEO_EXTRAS="${VIDEO_EXTRAS} ${m}"
done
VIDEO_STUDIO_LABELS=""
for m in ${VIDEO_EXTRAS}; do
  case "$m" in
    ltx)      VIDEO_STUDIO_LABELS="${VIDEO_STUDIO_LABELS}LTX-Video," ;;
    cogvideo) VIDEO_STUDIO_LABELS="${VIDEO_STUDIO_LABELS}CogVideoX-5B," ;;
    hunyuan)  VIDEO_STUDIO_LABELS="${VIDEO_STUDIO_LABELS}HunyuanVideo," ;;
  esac
done
VIDEO_STUDIO_LABELS="${VIDEO_STUDIO_LABELS%,}"
[[ -n "${VIDEO_EXTRAS// /}" ]] && install_video_studio "${VIDEO_EXTRAS}"

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
m.set_generation_params(duration=int('\${DURATION}'))
audio = m.generate(['\${PROMPT}'])[0].cpu()
torchaudio.save('\${OUTPUT}', audio, 32000)
print('Saved:', '\${OUTPUT}')
\"
WEOF
chmod +x /usr/local/bin/musicgen-generate
" && success "CLI wrapper scripts installed." || warn "Wrapper script install failed."

# ── Phase 5: Start AI services ───────────────────────────────────────────────
step "Phase 5/5: Starting services"

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

# Image generation handled by ComfyUI on port 8188

# Wan2.1 Gradio UI on port 7870
if [[ -d /opt/Wan2.1 ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/wan21-env/bin/activate
cd /opt/Wan2.1
export AGH_MODELS=${MODELS_DIR}
export TMPDIR=${TMPDIR_OVERRIDE}
nohup python gradio_app.py \
  > ${DATA_DIR}/wan21-gradio.log 2>&1 &
" && success "Wan2.1 Gradio UI starting on port 7870." || warn "Wan2.1 Gradio start failed."
  SERVICE_PORTS[wan21]=7870
  SERVICE_NAMES[wan21]="Wan2.1 — AI Video Generator (No Time Limits)"
fi

# AGH Video Studio (LTX / CogVideoX / Hunyuan) on port 7871
if [[ -f /opt/agh_video_studio.py ]]; then
  nsenter -t "${POD_PID}" -m -- bash -c "
source /opt/agh-video-env/bin/activate
export AGH_MODELS=${MODELS_DIR}
export TMPDIR=${TMPDIR_OVERRIDE}
export HF_HOME=${MODELS_DIR}/hf-cache
export AGH_VIDEO_MODELS='${VIDEO_STUDIO_LABELS:-}'
nohup python /opt/agh_video_studio.py > ${DATA_DIR}/agh-video-studio.log 2>&1 &
" && success "AGH Video Studio starting on port 7871." || warn "Video Studio start failed."
  SERVICE_PORTS[videostudio]=7871
  SERVICE_NAMES[videostudio]="AGH Video Studio — LTX/CogVideoX/Hunyuan"
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
[[ -n "${SERVICE_PORTS[wan21]:-}" ]]    && PORTAL_ROWS+="<tr><td>🎬</td><td><strong>Wan2.1 Video</strong></td><td><a href='http://localhost:${SERVICE_PORTS[wan21]}' target='_blank'>http://localhost:${SERVICE_PORTS[wan21]}</a></td><td>AI video — no time limits</td></tr>"
[[ -n "${SERVICE_PORTS[videostudio]:-}" ]] && PORTAL_ROWS+="<tr><td>🎞️</td><td><strong>AGH Video Studio</strong></td><td><a href='http://localhost:${SERVICE_PORTS[videostudio]}' target='_blank'>http://localhost:${SERVICE_PORTS[videostudio]}</a></td><td>LTX · CogVideoX · Hunyuan</td></tr>"
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

start_tunnel() {
  local name="$1"
  local port="$2"
  local logfile="/tmp/cf-tunnel-${name}.log"
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
[[ -n "${SERVICE_PORTS[wan21]:-}" ]]    && start_tunnel "wan21"    "${SERVICE_PORTS[wan21]}"
[[ -n "${SERVICE_PORTS[videostudio]:-}" ]] && start_tunnel "videostudio" "${SERVICE_PORTS[videostudio]}"
[[ -n "${SERVICE_PORTS[comfyui]:-}" ]]  && start_tunnel "comfyui"  "${SERVICE_PORTS[comfyui]}"
[[ -n "${SERVICE_PORTS[a1111]:-}" ]]    && start_tunnel "a1111"    "${SERVICE_PORTS[a1111]}"

# Inject public URLs into portal page
PORTAL_PUBLIC=""
for svc in portal desktop wan21 videostudio comfyui a1111 jupyter vscode; do
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
[[ -n "${TUNNEL_URLS[wan21]:-}" ]]    && echo -e "  ${GREEN}Wan2.1 Video:${NC}      ${TUNNEL_URLS[wan21]}"
[[ -n "${TUNNEL_URLS[videostudio]:-}" ]] && echo -e "  ${GREEN}Video Studio:${NC}      ${TUNNEL_URLS[videostudio]}"
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
