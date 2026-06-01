# AGH Secure Pods — System Reference

**Last updated:** 2026-05-27  
**Environment:** Shadeform GPU VM (Ubuntu 22.04)  
**Status:** Working — desktop accessible via public cloudflared URL

---

## What We Built

Two scripts that take a fresh Shadeform GPU VM from zero to a working AI workstation with a browser-accessible desktop.

```
Script 1: install_gpu_drivers.sh   ← Run first (NVIDIA + envpod + templates)
Script 2: setup_desktop.sh         ← Run second (XFCE desktop + apps + public URL)
```

### One-line install (run on Shadeform VM)

```bash
# Step 1 — NVIDIA + envpod
wget -qO agh_pre_installer.sh https://raw.githubusercontent.com/niksresearch/agh-installations/main/install_gpu_drivers.sh && sudo bash agh_pre_installer.sh

# Step 2 — Desktop + apps + public URL
wget -qO setup_desktop.sh https://raw.githubusercontent.com/niksresearch/agh-installations/main/setup_desktop.sh && sudo bash setup_desktop.sh
```

Prints a `https://xxxx.trycloudflare.com/vnc.html` URL at the end. Open it in a browser — full XFCE desktop.

---

## What Gets Installed

### After `install_gpu_drivers.sh`

| Component | Location | Notes |
|---|---|---|
| NVIDIA drivers | system | `ubuntu-drivers autoinstall`; fallback `nvidia-driver-580-server` |
| `envpod` CE | `/usr/local/bin/envpod` | Container-like pod runtime with overlay filesystem |
| Pod templates | `/opt/secure-pods/*.yaml` | 5 templates (see below) |
| Launcher helper | `/usr/local/bin/agh-secure-pod-launch` | Thin wrapper around envpod |
| Log dir | `/var/log/secure-pods/` | |

### After `setup_desktop.sh`

| Component | Location | Notes |
|---|---|---|
| envpod pod | `my-desktop` | Based on `gpu-desktop.yaml` |
| XFCE desktop | Inside pod | Via `Xvfb :1` + `startxfce4` |
| VNC server | `x11vnc` on port 5900 | No auth (POC) |
| noVNC (browser VNC) | `websockify` on port 6080 | `http://localhost:6080/vnc.html` |
| FFmpeg | Inside pod | `apt-get install ffmpeg` |
| Blender | Inside pod | `apt-get install blender` (3.x) |
| WhisperX | `/opt/whisperx-env/` | Python venv, CPU mode |
| cloudflared | `/usr/local/bin/cloudflared` | Free public tunnel |
| Tunnel log | `/tmp/cloudflared-tunnel.log` | URL printed here |

---

## Pod Templates

Located at `/opt/secure-pods/`:

| Template | Use case | CPU | RAM | GPU | Duration |
|---|---|---|---|---|---|
| `gpu-desktop.yaml` | XFCE desktop session | 4 cores | 16 GB | ✓ | 12h |
| `gpu-ml-training.yaml` | ML training jobs | 4 cores | 16 GB | ✓ | 8h |
| `llm-pod.yaml` | LLM inference server | 8 cores | 32 GB | ✓ | 24h |
| `agent-workspace.yaml` | AI agents (GitHub/PyPI/APIs) | 2 cores | 8 GB | — | 8h |
| `browser-pod.yaml` | Sandboxed browser | 2 cores | 4 GB | — | 4h |

All templates use `seccomp_profile: browser` and `audit.action_log: true`.

---

## Accessing the Desktop

### Public URL (via cloudflared — current method)
```
https://xxxx.trycloudflare.com/vnc.html
```
- URL is temporary, changes each time cloudflared restarts
- No auth — POC only
- Regenerate: `pkill cloudflared && cloudflared tunnel --url http://localhost:6080`

### SSH Tunnel (private, persistent)
```bash
# From your laptop
ssh -L 6080:127.0.0.1:6080 shadeform@<SERVER_IP>

# Then open in browser
http://localhost:6080/vnc.html
```

---

## Key Workarounds (Why We Don't Use Clean envpod Path)

### Problem: `envpod setup` fails on Shadeform
`envpod setup my-desktop` exits with GPG signature errors:
```
W: GPG error: http://archive.ubuntu.com ... At least one invalid signature was encountered.
```
**Root cause:** Pod runs with `no_new_privileges` + seccomp `browser` profile. This blocks GPG key verification during `apt-get update` inside the pod.

**Our fix:** Skip `envpod setup` entirely. Use `nsenter` to enter the pod's namespaces as host root (bypasses seccomp restrictions) and run `apt-get` directly:
```bash
nsenter -t <POD_PID> -m -u -i -n -p -- bash -c "apt-get install -y xfce4 ..."
```

### Problem: DNAT iptables rule blocks localhost:6080
envpod creates an OUTPUT chain DNAT rule: `localhost:6080 → <pod_IP>:6080`

Since our display stack (websockify) runs on the **host** (not inside the pod), this rule redirects traffic away from websockify to nothing.

**Our fix:** Delete the rule after pod start:
```bash
sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport 6080 \
  -j DNAT --to-destination 10.200.1.2:6080
```
`setup_desktop.sh` does this automatically.

### Problem: Clock stuck at midnight on fresh VM
Shadeform VMs sometimes boot with system clock at `00:00:00 UTC`.
**Fix:**
```bash
timedatectl set-ntp false
date -s "$(curl -sI https://google.com | grep -i '^Date:' | sed 's/Date: //' | tr -d '\r\n')"
```
`setup_desktop.sh` handles this at Step 1.

---

## Display Stack (How Desktop Works)

```
Xvfb :1            ← virtual framebuffer (headless X server)
  └── startxfce4   ← XFCE desktop renders into Xvfb
x11vnc             ← reads Xvfb framebuffer, serves VNC on port 5900
websockify :6080   ← wraps VNC in WebSocket, serves noVNC HTML on port 6080
  └── noVNC HTML   ← browser connects here, renders desktop
cloudflared        ← tunnels port 6080 to public trycloudflare.com URL
```

All processes started via `nsenter` inside pod namespace for isolation, but running as host root without seccomp restrictions.

---

## Apps Installed in Desktop

### FFmpeg
```bash
# Inside desktop terminal
ffmpeg -version
ffmpeg -i input.mp4 -c:v libx264 output.mp4
```

### Blender
```bash
# Launch from desktop Applications menu, or terminal:
blender
# Headless render:
blender --background scene.blend --render-output /tmp/render --render-frame 1
```

### WhisperX (speech-to-text)
```bash
# Activate venv first
source /opt/whisperx-env/bin/activate

# Transcribe audio
whisperx audio.mp3 --model base --output_dir /tmp/transcripts

# With diarization (who spoke when)
whisperx audio.mp3 --model base --diarize --hf_token <YOUR_TOKEN>
```
> **Note:** Installed in CPU mode. GPU acceleration requires testing (see Pending section).

---

## Pod Lifecycle

```bash
# Current desktop pod
sudo envpod ls                          # list all pods + status
sudo envpod start my-desktop            # start
sudo envpod stop my-desktop             # stop
sudo envpod destroy my-desktop          # delete pod + overlay (permanent)

# Run a command inside any pod
sudo envpod run my-desktop -- bash
sudo envpod run my-desktop -- nvidia-smi
```

---

## Launcher Helper

`agh-secure-pod-launch` wraps envpod to hide its complexity:

```bash
# Usage
agh-secure-pod-launch <pod-name> <template> <command...>

# Examples
agh-secure-pod-launch gpu-check gpu-ml-training nvidia-smi
agh-secure-pod-launch my-training gpu-ml-training python3 train.py
agh-secure-pod-launch llm-server llm-pod python3 -m vllm.entrypoints.api_server
agh-secure-pod-launch my-agent agent-workspace bash
```

---

## CE vs Premium (envpod)

| Feature | CE (what we have) | Premium |
|---|:---:|:---:|
| noVNC display at localhost:6080 | ✓ | ✓ |
| XFCE desktop | ✓ | ✓ |
| Audio over WebSocket | ✓ | ✓ |
| GPU passthrough (native) | — | ✓ |
| WebRTC display (low latency) | — | ✓ |
| Public `*.envpod.cloud` URL | — | ✓ |
| Multi-tunnel fleet dashboard | — | ✓ |

**GPU workaround:** `nsenter` enters host namespaces — GPU *may* be accessible from host's perspective even without CE GPU passthrough. **Not yet tested.**

---

## Pending / Next Steps

| # | Task | Priority |
|---|---|---|
| 1 | **Test GPU inside pod** — `sudo nsenter -t <POD_PID> -m -u -i -n -p -- nvidia-smi` | High — WhisperX CUDA, Blender GPU rendering |
| 2 | **Update `gpu-desktop.yaml`** — add dotfiles, resolution, `setup:` block per tutorial | Medium |
| 3 | **Install Chrome + VS Code** inside pod via nsenter | Medium |
| 4 | **Verify URL printing** in `setup_desktop.sh` works on fresh run | Medium |
| 5 | **Golden image strategy** — Shadeform VMs are ephemeral; need S3 snapshot plan | High |
| 6 | **Add Cloudflare Access auth** to public URL for production use | High before sharing |

### Golden Image Options
Since Shadeform VMs are destroyed on stop (all work lost):

| Option | How | Effort |
|---|---|---|
| **Shadeform snapshot** | Check if Shadeform offers VM snapshot/image save | Low — check dashboard |
| **S3 overlay backup** | `tar` the pod's overlay upper layer → S3; restore on new VM | Medium |
| **Script everything** | `setup_desktop.sh` already re-installs everything from scratch | Done — but 10+ min each time |
| **Docker image** | Package pod contents as Docker image, push to registry | Medium |

---

## Troubleshooting

### Desktop not showing / port 6080 not listening
```bash
pgrep -a websockify    # should show running
pgrep -a Xvfb          # should show running
ss -tlnp | grep 6080   # should show LISTEN on 127.0.0.1:6080

# If dead — re-run setup_desktop.sh
sudo bash setup_desktop.sh
```

### SSH tunnel "Connection refused"
```bash
# Check for DNAT rule blocking localhost
sudo iptables -t nat -L OUTPUT -n | grep 6080

# If shows DNAT — delete it
sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport 6080 \
  -j DNAT --to-destination 10.200.1.2:6080
```

### Cloudflared URL expired
```bash
pkill cloudflared
cloudflared tunnel --url http://localhost:6080
# Opens new tunnel, prints new URL
```

### Get pod PID (needed for nsenter)
```bash
ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | head -1
```

### envpod run syntax
```bash
# Correct — use -- separator
sudo envpod run my-desktop -- bash
sudo envpod run my-desktop -- nvidia-smi

# Wrong — crashes with "unexpected argument" error
sudo envpod run my-desktop bash
```

---

## File Reference

| File | Purpose |
|---|---|
| `install_gpu_drivers.sh` | Step 1: NVIDIA + envpod + templates + launcher |
| `setup_desktop.sh` | Step 2: XFCE desktop + FFmpeg + Blender + WhisperX + public URL |
| `TUTORIAL-DESKTOP-VNC.md` | Official envpod desktop tutorial (clean path reference) |
| `AGH-SYSTEM-REFERENCE.md` | This file |
| `/opt/secure-pods/*.yaml` | Pod templates (on Shadeform VM) |
| `/usr/local/bin/agh-secure-pod-launch` | Launcher helper (on Shadeform VM) |
| `/opt/whisperx-env/` | WhisperX Python venv (on Shadeform VM) |
