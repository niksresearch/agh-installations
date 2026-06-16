#!/usr/bin/env bash
# AGH Creative Suite — Bundle verification
#
# Confirms every component a bundle is supposed to install is actually present,
# and shows which AI services are currently running (listening on their ports).
#
# Usage:
#   sudo bash verify_bundle.sh 1     # verify Bundle 1 "Starter"
#   sudo bash verify_bundle.sh 2     # verify Bundle 2 "Creator"
#   sudo bash verify_bundle.sh 3     # verify Bundle 3 "Full Suite"
#
# Exit code 0 = all expected components present, 1 = something missing.
set -uo pipefail

BUNDLE="${1:-}"
[[ "$BUNDLE" =~ ^[123]$ ]] || { echo "Usage: sudo bash verify_bundle.sh <1|2|3>"; exit 2; }

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Paths (match setup_creative_suite.sh) ─────────────────────────────────────
[[ -f /etc/profile.d/agh-paths.sh ]] && source /etc/profile.d/agh-paths.sh
if [[ -z "${AGH_MODELS:-}" ]]; then
  for c in /ephemeral /data /mnt/data; do mountpoint -q "$c" 2>/dev/null && { AGH_DATA="$c"; AGH_MODELS="$c/models"; break; }; done
  AGH_DATA="${AGH_DATA:-/opt}"; AGH_MODELS="${AGH_MODELS:-/opt/models}"
fi
MODELS_DIR="${AGH_MODELS}"

# ── Pod (CE pods run tools in a mount namespace) ──────────────────────────────
POD_PID=$(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | head -1)
inpod() { if [[ -n "$POD_PID" ]]; then nsenter -t "$POD_PID" -m -- bash -c "$1"; else bash -c "$1"; fi; }

PASS=0; FAIL=0
ok()   { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${RED}✗${NC} $1 ${RED}— MISSING${NC}"; FAIL=$((FAIL+1)); }
note() { echo -e "  ${YELLOW}•${NC} $1"; }

# check_dir <label> <path>
check_dir()  { [[ -d "$2" ]] && ok "$1" || bad "$1  ($2)"; }
# check_file <label> <path>
check_file() { [[ -f "$2" ]] && ok "$1" || bad "$1  ($2)"; }
# check_import <label> <venv> <module>
check_import() {
  if inpod "source $2/bin/activate 2>/dev/null && python -c 'import $3' 2>/dev/null"; then ok "$1"; else bad "$1  ($2: import $3)"; fi
}
# check_port <label> <port>   (running service)
check_port() {
  if curl -s --connect-timeout 3 "http://127.0.0.1:$2" >/dev/null 2>&1 || ss -ltn 2>/dev/null | grep -q ":$2 "; then
    echo -e "  ${GREEN}●${NC} $1 — listening on :$2"
  else
    echo -e "  ${YELLOW}○${NC} $1 — not running (:$2)"
  fi
}

echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  AGH Bundle ${BUNDLE} verification${NC}"
echo -e "  Models dir: ${MODELS_DIR}"
echo -e "  Pod PID:    ${POD_PID:-<none — checking on host>}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"

# ── Always installed (every bundle) ───────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}Core (all bundles)${NC}"
inpod "command -v ffmpeg >/dev/null" && ok "FFmpeg" || bad "FFmpeg"
inpod "command -v blender >/dev/null" && ok "Blender" || bad "Blender"
check_dir   "ComfyUI"               "/opt/ComfyUI"
check_dir   "ComfyUI venv"          "/opt/comfyui-env"
check_import "MusicGen (audiocraft)" "/opt/audio-env" "audiocraft"
if ls "${MODELS_DIR}"/comfyui/checkpoints/*.safetensors >/dev/null 2>&1 \
   || ls "${MODELS_DIR}"/comfyui/unet/flux1-*.safetensors >/dev/null 2>&1; then
  ok "Image model (FLUX or SD checkpoint)"
else
  bad "Image model — no FLUX unet and no SD checkpoint in ${MODELS_DIR}/comfyui"
fi

# ── Bundle-specific components ────────────────────────────────────────────────
case "$BUNDLE" in
  1) APPS="flux wan21 esrgan" ;;
  2) APPS="flux wan21 hunyuan musicgen bark esrgan" ;;
  3) APPS="flux a1111 hunyuan wan21 ltx cogvideo esrgan musicgen bark devtools" ;;
esac

echo -e "\n${CYAN}${BOLD}Bundle ${BUNDLE} apps:${NC} ${APPS}"
for app in $APPS; do
  case "$app" in
    flux)
      if ls "${MODELS_DIR}"/comfyui/unet/flux1-*.safetensors >/dev/null 2>&1; then
        ok "FLUX weights (unet)"
      else
        note "FLUX weights absent — gated, needs HF_TOKEN. Demo falls back to SDXL/SD1.5."
      fi
      ;;
    wan21)
      check_dir  "Wan2.1 repo"  "/opt/Wan2.1"
      check_dir  "Wan2.1 venv"  "/opt/wan21-env"
      check_dir  "Wan2.1 model" "${MODELS_DIR}/wan21"
      ;;
    hunyuan)
      check_dir "AGH Video Studio venv (HunyuanVideo)" "/opt/agh-video-env"
      ;;
    bark)
      check_import "Bark TTS" "/opt/voice-env" "bark"
      ;;
    musicgen) : ;;  # covered in Core
    esrgan)
      check_dir  "Real-ESRGAN venv" "/opt/enhancement-env"
      check_file "Real-ESRGAN weights" "${MODELS_DIR}/realesrgan/RealESRGAN_x4plus.pth"
      ;;
    a1111)
      check_dir "Stable Diffusion (A1111)" "/opt/stable-diffusion-webui"
      ;;
    ltx|cogvideo)
      check_dir "AGH Video Studio venv (${app})" "/opt/agh-video-env"
      ;;
    devtools)
      inpod "command -v code-server >/dev/null" && ok "VS Code (code-server)" || bad "VS Code (code-server)"
      check_dir "JupyterLab venv" "/opt/jupyter-env"
      ;;
  esac
done

# ── Running services (ports) ──────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}Running services${NC}"
check_port "ComfyUI"           8188
[[ "$APPS" == *wan21*   ]] && check_port "Wan2.1 Gradio"    7870
[[ "$APPS" == *hunyuan* || "$APPS" == *ltx* || "$APPS" == *cogvideo* ]] && check_port "AGH Video Studio" 7871
[[ "$APPS" == *a1111*   ]] && check_port "Stable Diffusion" 7860
[[ "$APPS" == *devtools* ]] && { check_port "JupyterLab" 8888; check_port "VS Code" 8080; }
check_port "Portal"            9080

# ── GPU ───────────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}GPU${NC}"
nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null \
  | sed 's/^/  /' || note "nvidia-smi unavailable"

# ── Verdict ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}════════════════════════════════════════════════════════════════${NC}"
if [[ "$FAIL" -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}PASS${NC} — ${PASS} components present, 0 missing. Bundle ${BUNDLE} ready."
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
  exit 0
else
  echo -e "  ${RED}${BOLD}INCOMPLETE${NC} — ${PASS} present, ${RED}${FAIL} missing${NC}. See ✗ above."
  echo -e "  Re-run setup or check setup.log for the failed install step."
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
  exit 1
fi
