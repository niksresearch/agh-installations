#!/usr/bin/env bash
# AGH Secure Pods - Shadeform GPU Setup Script
#
# One-line install:
#   wget -qO install_drivers.sh https://raw.githubusercontent.com/niksresearch/agh-installations/main/install_gpu_drivers.sh && sudo bash setup.sh
#
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_STEPS=5
SECURE_PODS_DIR="/opt/secure-pods"

# Populated by confirm_or_select_os()
OS_ID=""        # ubuntu | debian
OS_CODENAME=""  # jammy | noble | focal | bullseye | bookworm
OS_VERSION=""   # 22.04 | 24.04 | 20.04 | 11 | 12

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}══ Step ${1}/${TOTAL_STEPS}: ${2}${NC}"; }

banner() {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║          AGH Secure Pods —  Setup                        ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_VERSION="${VERSION_ID:-}"
  fi
}

# Sets OS_ID, OS_CODENAME, OS_VERSION from a menu choice index
apply_os_choice() {
  case "$1" in
    1) OS_ID="ubuntu"; OS_VERSION="20.04"; OS_CODENAME="focal"     ;;
    2) OS_ID="ubuntu"; OS_VERSION="22.04"; OS_CODENAME="jammy"     ;;
    3) OS_ID="ubuntu"; OS_VERSION="24.04"; OS_CODENAME="noble"     ;;
    4) OS_ID="debian"; OS_VERSION="11";    OS_CODENAME="bullseye"  ;;
    5) OS_ID="debian"; OS_VERSION="12";    OS_CODENAME="bookworm"  ;;
  esac
}

# Prints the OS select menu and reads user choice into OS_* vars
prompt_os_selection() {
  echo ""
  echo -e "${BOLD}Select your operating system:${NC}"
  echo -e "  ${CYAN}1)${NC} Ubuntu 20.04 LTS (Focal Fossa)"
  echo -e "  ${CYAN}2)${NC} Ubuntu 22.04 LTS (Jammy Jellyfish)"
  echo -e "  ${CYAN}3)${NC} Ubuntu 24.04 LTS (Noble Numbat)"
  echo -e "  ${CYAN}4)${NC} Debian 11 (Bullseye)"
  echo -e "  ${CYAN}5)${NC} Debian 12 (Bookworm)"
  echo ""

  while true; do
    read -rp "$(echo -e "${BOLD}Enter choice [1-5]:${NC} ")" choice
    case "$choice" in
      [1-5]) apply_os_choice "$choice"; break ;;
      *) warn "Enter a number between 1 and 5." ;;
    esac
  done
}

# Auto-detect → confirm → fallback to menu
confirm_or_select_os() {
  detect_os

  local detected_label=""
  case "${OS_ID}:${OS_CODENAME}" in
    ubuntu:focal)    detected_label="Ubuntu 20.04 LTS (Focal Fossa)"    ;;
    ubuntu:jammy)    detected_label="Ubuntu 22.04 LTS (Jammy Jellyfish)" ;;
    ubuntu:noble)    detected_label="Ubuntu 24.04 LTS (Noble Numbat)"    ;;
    debian:bullseye) detected_label="Debian 11 (Bullseye)"               ;;
    debian:bookworm) detected_label="Debian 12 (Bookworm)"               ;;
    *)               detected_label="" ;;
  esac

  if [[ -n "$detected_label" ]]; then
    echo -e "${GREEN}Detected OS:${NC} ${BOLD}${detected_label}${NC}"
    read -rp "$(echo -e "${BOLD}Continue with this OS? [Y/n]:${NC} ")" yn
    case "${yn:-Y}" in
      [Yy]|"") info "Using: ${detected_label}" ;;
      *)        prompt_os_selection ;;
    esac
  else
    warn "Could not auto-detect a supported OS (detected: '${OS_ID:-unknown}' / '${OS_CODENAME:-unknown}')."
    prompt_os_selection
  fi

  echo ""
  success "OS confirmed: ${BOLD}${OS_ID} ${OS_VERSION} (${OS_CODENAME})${NC}"
}

# ── Step 1: Base packages ─────────────────────────────────────────────────────
install_base_packages() {
  step 1 "Installing base packages"
  apt-get update -y -q
  apt-get install -y -q \
      curl \
      wget \
      ca-certificates \
      git \
      pciutils \
      python3 \
      python3-pip \
      jq \
      linux-headers-"$(uname -r)" \
      build-essential \
      dkms
  success "Base packages installed."
}

# ── Shared: blacklist nouveau ─────────────────────────────────────────────────
blacklist_nouveau() {
  info "Blacklisting nouveau kernel module..."
  cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
  update-initramfs -u -q
  success "nouveau blacklisted."
}

# ── Step 2a: NVIDIA on Ubuntu ─────────────────────────────────────────────────
install_nvidia_ubuntu() {
  info "Installing NVIDIA driver via ubuntu-drivers (this may take a few minutes)..."
  apt-get install -y -q ubuntu-drivers-common

  # ubuntu-drivers autoinstall picks the recommended driver for the detected GPU
  ubuntu-drivers autoinstall || {
    warn "ubuntu-drivers autoinstall failed, falling back to nvidia-driver-580-server..."
    apt-get install -y -q \
        nvidia-driver-580-server \
        nvidia-utils-580-server \
        nvidia-modprobe
  }
}

# ── Step 2b: NVIDIA on Debian ─────────────────────────────────────────────────
install_nvidia_debian() {
  info "Adding non-free components to apt sources..."

  local sources_file="/etc/apt/sources.list"

  if [[ "${OS_CODENAME}" == "bookworm" ]]; then
    # Debian 12 split firmware into non-free-firmware
    sed -i 's/^\(deb .*main\)$/\1 contrib non-free non-free-firmware/' "${sources_file}"
  else
    # Debian 11 and earlier
    sed -i 's/^\(deb .*main\)$/\1 contrib non-free/' "${sources_file}"
  fi

  info "Updating apt after adding non-free..."
  apt-get update -y -q

  info "Installing NVIDIA driver from non-free (this may take a few minutes)..."
  apt-get install -y -q \
      nvidia-driver \
      firmware-misc-nonfree
}

# ── Step 2: NVIDIA driver (dispatch) ─────────────────────────────────────────
install_nvidia() {
  step 2 "Installing NVIDIA GPU driver for ${OS_ID} ${OS_VERSION}"

  blacklist_nouveau

  case "${OS_ID}" in
    ubuntu) install_nvidia_ubuntu ;;
    debian) install_nvidia_debian ;;
  esac

  modprobe nvidia 2>/dev/null && success "NVIDIA kernel module loaded." \
    || warn "modprobe deferred — module loads on next reboot."

  if nvidia-smi &>/dev/null; then
    success "GPU detected:"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader \
      | while IFS=',' read -r name drv mem; do
          echo -e "   ${GREEN}•${NC} ${BOLD}${name}${NC} | Driver: ${drv} | VRAM: ${mem}"
        done
  else
    warn "nvidia-smi not available yet — will work after reboot."
  fi
}

# ── Step 3: envpod ────────────────────────────────────────────────────────────
install_envpod() {
  step 3 "Installing envpod (Secure Pods runtime)"
  curl -fsSL https://envpod.dev/install.sh | bash
  hash -r
  ENVPOD_BIN=$(command -v envpod 2>/dev/null || echo "/usr/local/bin/envpod")
  [[ -x "${ENVPOD_BIN}" ]] || { error "envpod not found after install. Check https://envpod.dev"; exit 1; }
  success "envpod installed: $("${ENVPOD_BIN}" --version 2>&1 | head -1)"
}

# ── Step 4: Pod templates ─────────────────────────────────────────────────────
write_pod_templates() {
  step 4 "Writing pod templates → ${SECURE_PODS_DIR}"
  mkdir -p "${SECURE_PODS_DIR}"
  chmod 755 "${SECURE_PODS_DIR}"

  cat > "${SECURE_PODS_DIR}/gpu-ml-training.yaml" <<'EOF'
name: ml-training
type: standard
backend: native

devices:
  gpu: true

processor:
  cores: 4.0
  memory: "16GB"

budget:
  max_duration: "8h"

network:
  mode: Monitored
  dns:
    mode: Allowlist
    allow:
      - "pypi.org"
      - "*.pypi.org"
      - "huggingface.co"
      - "*.huggingface.co"
      - "files.pythonhosted.org"

security:
  seccomp_profile: browser
  shm_size: "1GB"

audit:
  action_log: true
EOF

  cat > "${SECURE_PODS_DIR}/gpu-desktop.yaml" <<'EOF'
name: gpu-desktop
type: standard
backend: native

devices:
  gpu: true
  display: true
  audio: true

processor:
  cores: 4.0
  memory: "16GB"

budget:
  max_duration: "12h"

network:
  mode: Monitored
  dns:
    mode: Denylist
    deny:
      - "*.internal"
      - "*.corp"
      - "*.local"

security:
  seccomp_profile: browser
  shm_size: "512MB"

audit:
  action_log: true
EOF

  cat > "${SECURE_PODS_DIR}/llm-pod.yaml" <<'EOF'
name: llm-pod
type: standard
backend: native

devices:
  gpu: true

processor:
  cores: 8.0
  memory: "32GB"

budget:
  max_duration: "24h"

network:
  mode: Monitored
  dns:
    mode: Allowlist
    allow:
      - "huggingface.co"
      - "*.huggingface.co"
      - "pypi.org"
      - "*.pypi.org"
      - "files.pythonhosted.org"

security:
  seccomp_profile: browser
  shm_size: "4GB"

audit:
  action_log: true
EOF

  cat > "${SECURE_PODS_DIR}/agent-workspace.yaml" <<'EOF'
name: agent-workspace
type: standard
backend: native

filesystem:
  system_access: advanced

processor:
  cores: 2.0
  memory: "8GB"

budget:
  max_duration: "8h"

network:
  mode: Monitored
  dns:
    mode: Allowlist
    allow:
      - "api.anthropic.com"
      - "api.openai.com"
      - "github.com"
      - "*.github.com"
      - "pypi.org"
      - "*.pypi.org"
      - "registry.npmjs.org"
      - "*.npmjs.org"

audit:
  action_log: true
EOF

  cat > "${SECURE_PODS_DIR}/browser-pod.yaml" <<'EOF'
name: browser-pod
type: standard
backend: native

devices:
  display: true
  audio: true

processor:
  cores: 2.0
  memory: "4GB"

budget:
  max_duration: "4h"

network:
  mode: Monitored
  dns:
    mode: Denylist
    deny:
      - "*.internal"
      - "*.corp"
      - "*.local"

security:
  seccomp_profile: browser
  shm_size: "256MB"

audit:
  action_log: true
EOF

  chmod 644 "${SECURE_PODS_DIR}"/*.yaml
  success "Templates written:"
  for f in "${SECURE_PODS_DIR}"/*.yaml; do
    echo -e "   ${GREEN}•${NC} $(basename "$f")"
  done
}

# ── Step 5: Launcher helper ───────────────────────────────────────────────────
install_launcher() {
  step 5 "Installing agh-secure-pod-launch helper"

  cat > /usr/local/bin/agh-secure-pod-launch <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

if [[ $# -lt 3 ]]; then
  echo -e "${BOLD}Usage:${NC} agh-secure-pod-launch <pod-name> <template> <command...>"
  echo ""
  echo -e "${CYAN}Available templates:${NC}"
  for f in /opt/secure-pods/*.yaml; do
    echo "  • $(basename "${f%.yaml}")"
  done
  exit 1
fi

POD_NAME="$1"; TEMPLATE="$2"; shift 2
TEMPLATE_FILE="/opt/secure-pods/${TEMPLATE}.yaml"

[[ -f "${TEMPLATE_FILE}" ]] || {
  echo -e "${RED}[ERROR]${NC} Template not found: ${TEMPLATE_FILE}"
  echo "Run: ls /opt/secure-pods/   to see available templates."
  exit 1
}

echo -e "${CYAN}[envpod]${NC} Initialising pod '${BOLD}${POD_NAME}${NC}' with template '${TEMPLATE}'..."
envpod init "${POD_NAME}" -c "${TEMPLATE_FILE}" || true

echo -e "${CYAN}[envpod]${NC} Launching: $*"
envpod run "${POD_NAME}" "$@"
LAUNCHER

  chmod +x /usr/local/bin/agh-secure-pod-launch
  mkdir -p /var/log/secure-pods
  success "agh-secure-pod-launch installed at /usr/local/bin/agh-secure-pod-launch"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  info "Cleaning apt cache..."
  apt-get autoremove -y -q
  apt-get clean -q
  rm -rf /var/lib/apt/lists/*
}

# ── Final summary ─────────────────────────────────────────────────────────────
show_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║                  Setup Complete!                         ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}System:${NC} ${OS_ID} ${OS_VERSION} (${OS_CODENAME})"
  echo ""
  echo -e "${BOLD}Quick-start examples:${NC}"
  echo ""
  echo -e "  ${CYAN}# Check GPU${NC}"
  echo -e "  nvidia-smi"
  echo ""
  echo -e "  ${CYAN}# Run a Python ML training script in a secure GPU pod${NC}"
  echo -e "  agh-secure-pod-launch my-training gpu-ml-training python3 train.py"
  echo ""
  echo -e "  ${CYAN}# Run an LLM inference server (large VRAM + 24h budget)${NC}"
  echo -e "  agh-secure-pod-launch llm-server llm-pod python3 -m vllm.entrypoints.api_server"
  echo ""
  echo -e "  ${CYAN}# Launch an agent workspace (can reach GitHub, PyPI, Anthropic API)${NC}"
  echo -e "  agh-secure-pod-launch my-agent agent-workspace bash"
  echo ""
  echo -e "  ${CYAN}# List all available pod templates${NC}"
  echo -e "  ls ${SECURE_PODS_DIR}/"
  echo ""
  echo -e "  ${CYAN}# Show envpod help${NC}"
  echo -e "  envpod --help"
  echo ""

  if ! nvidia-smi &>/dev/null; then
    echo -e "${YELLOW}┌─ Action required ───────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│${NC}  NVIDIA driver installed but GPU not yet active.             ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${BOLD}Reboot the instance${NC}, then verify with: ${CYAN}nvidia-smi${NC}         ${YELLOW}│${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { error "Run as root: sudo bash $0"; exit 1; }

banner
info "Host: $(hostname)  |  Kernel: $(uname -r)  |  Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

export DEBIAN_FRONTEND=noninteractive

confirm_or_select_os
install_base_packages
install_nvidia
install_envpod
write_pod_templates
install_launcher
cleanup
show_summary
