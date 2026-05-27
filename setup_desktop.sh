#!/usr/bin/env bash
# AGH Secure Pods - Virtual Desktop Setup Script
#
# Run AFTER agh_pre_installer.sh completes.
#
# One-line install:
#   wget -qO setup_desktop.sh https://raw.githubusercontent.com/niksresearch/agh-installations/main/setup_desktop.sh && sudo bash setup_desktop.sh
#
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_STEPS=7
POD_NAME="my-desktop"
DISPLAY_NUM=":1"
VNC_PORT=5900
NOVNC_PORT=6080

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}══ Step ${1}/${TOTAL_STEPS}: ${2}${NC}"; }

banner() {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║       AGH Secure Pods — Virtual Desktop Setup            ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

[[ $EUID -eq 0 ]] || { error "Run as root: sudo bash $0"; exit 1; }

banner
info "Host: $(hostname)  |  Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# ── Password prompt ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Set a password for the virtual desktop:${NC}"
echo -e "${CYAN}(Minimum 6 characters — you'll enter this when opening the desktop URL)${NC}"
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
echo ""

# ── Step 1: Fix time ──────────────────────────────────────────────────────────
step 1 "Fixing system time"
CURRENT_HOUR=$(date +%H)
if [[ "$CURRENT_HOUR" == "00" ]]; then
  warn "Clock appears stuck at midnight. Syncing from Google..."
  date -s "$(curl -sI https://google.com | grep -i '^Date:' | sed 's/Date: //' | tr -d '\r\n')" 2>/dev/null || true
fi
timedatectl set-ntp false 2>/dev/null || true
success "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# ── Step 2: Init and start pod ────────────────────────────────────────────────
step 2 "Initialising desktop pod"

TEMPLATE="/usr/local/share/envpod/examples/desktop-user.yaml"
[[ -f "$TEMPLATE" ]] || TEMPLATE="/opt/secure-pods/gpu-desktop.yaml"

# Destroy existing if present
envpod destroy "${POD_NAME}" 2>/dev/null && info "Removed existing pod." || true

envpod init "${POD_NAME}" -c "${TEMPLATE}"
envpod start "${POD_NAME}"

info "Waiting for pod to start..."
sleep 3

POD_PID=$(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | head -1)
[[ -n "$POD_PID" ]] || { error "Pod PID not found. Run: envpod status ${POD_NAME}"; exit 1; }
success "Pod running. PID: ${POD_PID}"

# ── Step 3: Install desktop stack ────────────────────────────────────────────
step 3 "Installing desktop environment (XFCE + VNC + noVNC)"

nsenter -t "${POD_PID}" -m -u -i -n -p -- bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y --no-install-recommends \
  xfce4 xfce4-terminal dbus-x11 \
  xvfb x11vnc \
  novnc websockify \
  x11-xserver-utils fonts-dejavu-core \
  2>/dev/null
"
success "Desktop stack installed."

# ── Step 4: Install apps ──────────────────────────────────────────────────────
step 4 "Installing apps (FFmpeg + Blender + WhisperX)"

info "Installing FFmpeg..."
nsenter -t "${POD_PID}" -m -u -i -n -p -- bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get install -y ffmpeg 2>/dev/null
" && success "FFmpeg installed." || warn "FFmpeg install failed."

info "Installing Blender..."
nsenter -t "${POD_PID}" -m -u -i -n -p -- bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get install -y blender 2>/dev/null
" && success "Blender installed." || warn "Blender install failed."

info "Installing WhisperX (CPU mode — takes 5-10 min)..."
nsenter -t "${POD_PID}" -m -u -i -n -p -- bash -c "
apt-get install -y python3-pip python3-venv git 2>/dev/null
python3 -m venv /opt/whisperx-env
source /opt/whisperx-env/bin/activate
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
pip install --quiet whisperx
" && success "WhisperX installed at /opt/whisperx-env." || warn "WhisperX install failed."

# ── Step 5: Start display server ─────────────────────────────────────────────
step 5 "Starting display + VNC server"

pkill Xvfb    2>/dev/null || true
pkill x11vnc  2>/dev/null || true
pkill websockify 2>/dev/null || true
sleep 1

# Store VNC password inside pod's mount namespace
nsenter -t "${POD_PID}" -m -- \
  x11vnc -storepasswd "${VNC_PASS}" /etc/x11vnc.pass

# Xvfb + XFCE: run inside full pod namespace
nsenter -t "${POD_PID}" -m -u -i -n -p -- bash -c "
Xvfb ${DISPLAY_NUM} -screen 0 1920x1080x24 &
sleep 2
DISPLAY=${DISPLAY_NUM} startxfce4 &
echo 'Display started'
"
sleep 5

# x11vnc: mount namespace only (finds Xvfb socket), stays on HOST network so websockify can reach it
nsenter -t "${POD_PID}" -m -- \
  x11vnc -display ${DISPLAY_NUM} -forever -rfbauth /etc/x11vnc.pass \
  -listen 0.0.0.0 -rfbport ${VNC_PORT} &
sleep 2

# websockify: runs on HOST network directly (connects to host's VNC port)
websockify --web /usr/share/novnc/ ${NOVNC_PORT} 127.0.0.1:${VNC_PORT} &
sleep 3

# Remove DNAT rule that blocks localhost:6080 reaching websockify
iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport "${NOVNC_PORT}" \
  -j DNAT --to-destination "$(envpod ls 2>/dev/null | grep "${POD_NAME}" | awk '{print $3}'):${NOVNC_PORT}" \
  2>/dev/null || true

# Verify ports
if ss -tlnp | grep -q ":${NOVNC_PORT}"; then
  success "noVNC listening on port ${NOVNC_PORT}."
else
  warn "Port ${NOVNC_PORT} not detected. Check: ss -tlnp | grep ${NOVNC_PORT}"
fi

# ── Step 6: Install cloudflared for public URL ────────────────────────────────
step 6 "Setting up public URL (cloudflared)"

if ! command -v cloudflared &>/dev/null; then
  info "Downloading cloudflared..."
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi
success "cloudflared ready."

# ── Step 7: Start tunnel ──────────────────────────────────────────────────────
step 7 "Starting public tunnel"

# Kill any existing tunnel
pkill cloudflared 2>/dev/null || true
sleep 1

TUNNEL_LOG="/tmp/cloudflared-tunnel.log"
cloudflared tunnel --url "http://localhost:${NOVNC_PORT}" > "${TUNNEL_LOG}" 2>&1 &
TUNNEL_PID=$!

info "Waiting for tunnel URL (up to 60s)..."
PUBLIC_URL=""
for i in $(seq 1 60); do
  PUBLIC_URL=$(grep -o 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' "${TUNNEL_LOG}" 2>/dev/null | head -1 || true)
  if [[ -n "$PUBLIC_URL" ]]; then
    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}  PUBLIC URL READY:${NC}"
    echo -e "${BOLD}${GREEN}  ${PUBLIC_URL}/vnc.html${NC}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    break
  fi
  sleep 1
done

# ── Done ─────────────────────────────────────────────────────────────────────
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "unknown")

echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║              Virtual Desktop Ready!                      ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Apps installed:${NC}"
echo -e "  ${GREEN}•${NC} FFmpeg"
echo -e "  ${GREEN}•${NC} Blender"
echo -e "  ${GREEN}•${NC} WhisperX  (activate: source /opt/whisperx-env/bin/activate)"
echo ""
echo -e "${BOLD}Access:${NC}"
if [[ -n "$PUBLIC_URL" ]]; then
  echo -e "  ${GREEN}${BOLD}Public URL:${NC}   ${PUBLIC_URL}/vnc.html"
  echo -e "  ${YELLOW}Password:${NC}     Use the password you set during setup"
  echo -e "  ${YELLOW}Note:${NC} URL is temporary — regenerate: cloudflared tunnel --url http://localhost:${NOVNC_PORT}"
else
  warn "Tunnel URL not captured. Run manually:"
  echo -e "  cloudflared tunnel --url http://localhost:${NOVNC_PORT}"
  echo -e "  Then open the printed URL + /vnc.html"
fi
echo ""
echo -e "  ${CYAN}SSH tunnel:${NC}   ssh -i your-key.pem -N -L ${NOVNC_PORT}:127.0.0.1:${NOVNC_PORT} shadeform@${SERVER_IP}"
echo -e "  ${CYAN}Local URL:${NC}    http://localhost:${NOVNC_PORT}/vnc.html"
echo ""
