# Tutorial — XFCE desktop in a CE pod over SSH tunnel to localhost

---

## ⚠️ AGH Status (as of 2026-06-01)

The clean tutorial path (`envpod setup`) **fails on Shadeform VMs** due to GPG signature errors inside the pod's seccomp context. Use our scripts instead.

### AGH Scripts (use these)

| Script | Purpose | When to use |
|---|---|---|
| `setup_creative_suite.sh` | Full AI creative workstation (desktop + AI apps) | **Primary — use this** |
| `setup_desktop.sh` | Desktop only (XFCE + VNC + cloudflared) | Desktop without AI apps |
| `install_gpu_drivers.sh` | NVIDIA drivers + envpod + pod templates | Run first on fresh VM |

**One-command setup (fresh Shadeform H100/H200):**

```bash
# Step 1 — NVIDIA + envpod (run once per VM)
wget -qO agh_pre_installer.sh https://raw.githubusercontent.com/niksresearch/agh-installations/main/install_gpu_drivers.sh && sudo bash agh_pre_installer.sh

# Step 2 — Creative suite (desktop + AI apps)
wget -qO setup_creative_suite.sh https://raw.githubusercontent.com/niksresearch/agh-installations/main/setup_creative_suite.sh && sudo bash setup_creative_suite.sh
```

Prints `https://xxxx.trycloudflare.com/vnc.html` at end — open in browser, enter VNC password.

### Key Workarounds vs Clean Tutorial

| Issue | Clean path | Our workaround |
|---|---|---|
| `envpod setup` fails (GPG) | `sudo envpod setup my-desktop` | `nsenter -t <PID> -m` to bypass seccomp |
| Public URL (Premium only) | `*.envpod.cloud` | cloudflared free tunnel |
| x11vnc + websockify namespaces | Not an issue in clean path | x11vnc: `nsenter -m` only; websockify: host namespace |
| VNC auth | Handled by envpod | `x11vnc -rfbauth /etc/x11vnc.pass` |

Once envpod fixes the Shadeform GPG bug, we can revert to the 3-step clean path below.

---

**A full graphical Linux desktop running inside an envpod on a
remote host, accessible from your laptop's browser via an SSH
tunnel — no open ports, no public URLs, no DNS.**

Uses `examples/desktop-user.yaml` (CE feature — no license required).
Works on any Linux host that has envpod CE installed: cloud VPS,
spare lab machine, home lab, bare metal. The desktop renders via
**noVNC** (an in-browser VNC client) bundled in the pod and served
over a local HTTP port; SSH tunnels that port back to your laptop
and the browser sees it as `http://localhost:6080`.

**What you get when it works:**

- Full XFCE desktop in your browser: Chrome, VS Code (or code-server
  fallback), file manager, terminal, system apps
- Your host's home directory (select dirs) mounted into the pod —
  `Documents/`, `Projects/`, `src/`
- Everything overlay-isolated: changes go to the pod's COW layer,
  your real home directory is untouched
- ~4 GB of RAM + 2 CPUs reserved per desktop (configurable)

**Time:** 5 minutes to run (after envpod is installed on the host;
first-time install takes 3–5 minutes for the XFCE + Chrome + VS
Code setup). Subsequent boots ~20 seconds.

---

## Prerequisites

### On the remote host (where the pod will run)

- Linux (Ubuntu 22.04+, Debian 12+, RHEL 9, or similar)
- `envpod` CE installed and in the `envpod` group is set up for
  your user (`groups | grep envpod`)
- SSH access from your laptop

Install envpod CE if you haven't:

```bash
curl -fsSL https://envpod.dev/install.sh | sh
envpod --version       # should show 0.1.16+ (CE)
```

### On your laptop

- A modern browser (Chrome / Firefox / Safari)
- SSH client (built-in on Linux/macOS; WSL or PuTTY on Windows)
- That's it. No VNC client app, no noVNC install. The pod serves
  noVNC; your browser consumes it over the tunnel.

---

## Step 1 — Init the desktop pod (on the remote host)

```bash
# SSH into the remote host
ssh you@remote.example.com

# Init the pod from the stock example
sudo envpod init my-desktop -c examples/desktop-user.yaml
```

The `desktop-user.yaml` config does three important things:

```yaml
web_display:
  type: novnc                 # ← noVNC server (CE) bound to localhost
  port: 6080                  # ← HTTP port on the pod host
  resolution: "1920x1080"
  audio: true

host_user:
  clone_host: true            # ← copy your user account into the pod
  dirs:
    - Documents
    - Projects
    - src                     # ← these dirs get bind-mounted in

devices:
  desktop_env: xfce           # ← XFCE as the desktop environment
```

The `clone_host: true` line is the key: envpod reads your host's
`/etc/passwd` + `/etc/group` + select `$HOME` subdirs and injects
them into the pod's overlay. The overlay isolates writes — your
real home is read-only from the pod's perspective, any changes go
to the pod's COW layer.

## Step 2 — Run setup (downloads XFCE + Chrome + VS Code)

```bash
sudo envpod setup my-desktop
```

This takes 3–5 minutes on first run. In CE v0.1.16+ you'll see a
**live spinner + dimmed tail of the setup log** instead of a blank
screen — e.g.:

```
  [2/5] DEBIAN_FRONTEND=noninteractive apt-get install -y …  ⠋  2:04  Get:47 http://archive.ubuntu.com/ubuntu jammy-updates/main amd64 xfce4…
```

If any optional step fails (Chrome CDN unreachable, VS Code apt repo
flaky), setup continues — the pod is usable with `chromium-browser`
or `code-server` fallbacks. See `examples/desktop-user.yaml` for the
fallback chains; the relevant errors appear at the end of setup with
a copy-paste retry hint.

## Step 3 — Start the pod

```bash
sudo envpod start my-desktop
```

The pod boots in the background, starts XFCE + noVNC + audio, and
binds port `6080` on the **pod host's loopback interface only**
(not `0.0.0.0`). You can verify:

```bash
ss -tlnp | grep 6080
# LISTEN 0 ... 127.0.0.1:6080 ...
```

Port 6080 is **not exposed** on the public network. That's
deliberate — you reach it via SSH tunnel, not HTTP.

Confirm the pod is running:

```bash
sudo envpod ls | grep my-desktop
# my-desktop   running   …
```

## Step 4 — Tunnel 6080 from your laptop to the remote host

From your **laptop** (not the remote host):

```bash
ssh -L 6080:127.0.0.1:6080 you@remote.example.com
```

Breakdown:

- `-L 6080:...` — forward *local* port 6080
- `127.0.0.1:6080` — to the *remote side's* loopback port 6080 (where
  the pod is listening)
- `you@remote.example.com` — the SSH target

Leave this SSH session open. If you close it, the tunnel closes and
the desktop becomes unreachable.

**Tip:** if port 6080 on your laptop is already in use, swap the
local port: `ssh -L 8100:127.0.0.1:6080 you@remote.example.com` →
then open `http://localhost:8100`.

## Step 5 — Open the desktop in your browser

On your laptop, open:

<http://localhost:6080>

You should see the noVNC landing page with a **Connect** button.
Click it, and the full XFCE desktop renders inline in the browser
tab. Click through to Chrome or the file manager — it's a real
Linux desktop, just delivered through a websocket over the SSH
tunnel.

Your laptop keyboard + mouse both work. Clipboard integration is
partial (text copy/paste works; images may not). Audio plays through
your laptop's browser (via Opus/WebM over WebSocket when
`web_display.audio: true`).

## Pod lifecycle

| Action | Command | When |
|---|---|---|
| Start | `sudo envpod start my-desktop` | After init, on reboot |
| Stop | `sudo envpod stop my-desktop` | Clean shutdown (~5s) |
| Restart | `sudo envpod stop my-desktop && sudo envpod start my-desktop` | After config changes |
| Freeze | `sudo envpod freeze my-desktop` | Pause (SIGSTOP everything) |
| Resume | `sudo envpod resume my-desktop` | Un-pause |
| Destroy | `sudo envpod destroy my-desktop` | Permanent delete (overlay + vault) |
| Status | `sudo envpod ls my-desktop` | See resource usage |
| Audit | `sudo envpod audit my-desktop` | See what happened |

## Customize for your setup

### Different base image / preinstalled packages

```yaml
# pod.yaml
setup:
  - apt-get install -y libreoffice inkscape gimp blender
  - pip install jupyterlab numpy pandas
```

Add whatever `apt-get`/`pip` commands you'd run on a fresh Ubuntu.
Setup runs once — after that the pod boots with everything already
installed (cached in the overlay upper layer).

### Include dotfiles from host

```yaml
# pod.yaml
host_user:
  clone_host: true
  include_dotfiles:
    - .bashrc
    - .gitconfig
    - .vimrc
    - .ssh/config     # ← your SSH config for git remotes, etc.
```

envpod reads these from your host `$HOME`, copies them into the
pod's overlay once at init. The pod sees them as writable — changes
stay in the overlay.

### Different resolution / multi-monitor

```yaml
web_display:
  type: novnc
  port: 6080
  resolution: "2560x1440"       # QHD single monitor
```

Multi-monitor is not supported via noVNC (browser window = one
framebuffer). Use WebRTC display (Premium) for multi-monitor.

### CE vs. Premium at a glance

| Feature | CE | Premium |
|---|:---:|:---:|
| noVNC display at `localhost:6080` | ✓ | ✓ |
| XFCE / Openbox / Sway | ✓ | ✓ |
| Audio over WebSocket | ✓ | ✓ |
| GPU passthrough (for 3D apps) | — | ✓ |
| WebRTC display (lower latency) | — | ✓ |
| Public `*.envpod.cloud` URL (cloud-mode) | — | ✓ |
| Multi-tunnel fleet dashboard | — | ✓ |

Everything in this tutorial works on CE. Premium mostly adds
performance + cloud-hosted public URLs.

## Security notes

**Port 6080 is loopback-only on the pod host.** Anyone with SSH
access to your remote host can reach it; people *without* SSH
access cannot. If you run multiple users on the same remote, put
each in their own pod with a different `web_display.port`, then
tunnel each separately.

**The pod is isolated.** Even with `host_user.clone_host: true`, the
pod:

- Can't write to your real home directory (COW overlay)
- Can't see processes outside the pod (PID namespace)
- Can't reach internal services unless you explicitly allow their
  domains in `network.dns.allow` (the default CE `Monitored` mode
  logs but does not block — tighten to `Allowlist` for
  stricter isolation)
- Can't access other pods' files without an explicit mount

**The SSH tunnel is end-to-end encrypted.** Your laptop ↔ remote
traffic rides inside your existing SSH connection. noVNC itself
uses plain HTTP between the pod and the browser-over-tunnel, which
is fine because the tunnel is encrypted.

## Troubleshooting

### Desktop doesn't appear / noVNC page times out

Check the pod is actually running and listening:

```bash
sudo envpod ls my-desktop
ss -tlnp | grep 6080
```

If the pod is running but port 6080 isn't listening, the XFCE or
noVNC service inside didn't start. Check the pod's boot log:

```bash
sudo envpod audit my-desktop --tail 50 --filter display
```

Fallback: manually start the desktop inside the pod:

```bash
sudo envpod run my-desktop -b -- startxfce4
```

### Chrome won't launch / `--no-sandbox` error

envpod's namespaces *are* Chrome's sandbox — the nested Chrome
sandbox would fail trying to unshare what's already unshared.
`examples/desktop-user.yaml` patches the Chrome desktop file to add
`--no-sandbox`. If you installed Chrome manually after setup, run:

```bash
sudo envpod run my-desktop -- bash -c \
  "sed -i 's|Exec=/usr/bin/google-chrome-stable|Exec=/usr/bin/google-chrome-stable --no-sandbox|g' /usr/share/applications/google-chrome.desktop"
```

Restart the desktop session (log out and back in via XFCE) for the
change to take effect.

### "Apt can't find package X" during setup

Usually a DNS allowlist miss. The default allowlist in
`desktop-user.yaml` covers Ubuntu + Google Chrome + VS Code + cloud-
provider package mirrors. If you're on a distro or cloud provider
with a different mirror name, add it to `network.dns.setup_allow`
(setup-phase only — removed at run-time):

```yaml
network:
  dns:
    setup_allow:
      - "mirror.example.cloud"
```

Then re-run `envpod setup my-desktop` — setup is idempotent.

### SSH tunnel closes unexpectedly

Add `ServerAliveInterval 60` to `~/.ssh/config` for the remote:

```
Host remote.example.com
    HostName remote.example.com
    User you
    ServerAliveInterval 60
    ServerAliveCountMax 3
    LocalForward 6080 127.0.0.1:6080
```

Then `ssh remote.example.com` opens the tunnel automatically on
every connection. Run in the background with `-f -N` when you just
need the tunnel without a shell:

```bash
ssh -f -N -L 6080:127.0.0.1:6080 you@remote.example.com
```

Kill it later with `pkill -f "ssh.*6080:127.0.0.1"` or find the pid
in `ps aux | grep ssh`.

### Fleet of desktops — one per teammate

Give each user their own pod on different local ports:

```bash
# On the remote host
sudo envpod init alice-desktop -c examples/desktop-user.yaml
sudo envpod init bob-desktop   -c examples/desktop-user.yaml

# Edit each pod's pod.yaml to change web_display.port
# Or clone with an overridden port:
sudo envpod clone my-desktop charlie-desktop --port 6081
```

Each teammate tunnels their own port from their laptop; no
collisions, no shared state. Everyone sees their own dotfiles + home
dirs via `clone_host`.

---

## AGH Creative Suite

`setup_creative_suite.sh` extends the desktop with AI creative tools. Users pick a bundle at setup time:

| Bundle | Apps | Size | Time |
|---|---|---|---|
| **Starter** | ComfyUI + FLUX + Wan2.1 + Real-ESRGAN | ~40GB | ~20min |
| **Creator** | Starter + HunyuanVideo + MusicGen + Bark TTS | ~140GB | ~60min |
| **Full Suite** | Everything including A1111, LTX-Video, CogVideoX, VS Code | ~170GB | ~90min |
| **Custom** | User picks individual apps | varies | varies |

Always installed in all bundles: **Fooocus** (Midjourney-style UI), **Chrome**, GIMP, Krita, Kdenlive, Audacity, Inkscape, ComfyUI, FFmpeg, Blender, WhisperX.

**No SSH needed.** Setup prints public URLs for every service. Inside the desktop, Chrome opens the portal automatically.

**AGH Portal** (`http://localhost:9080` or public URL) — one page, all services, clickable links.

| Port | Service | Notes |
|---|---|---|
| 9080 | **AGH Portal** | Start here — links to everything |
| 6080 | Desktop (noVNC) | Full XFCE desktop |
| 7865 | Fooocus | Midjourney-style image gen |
| 7870 | Wan2.1 Video | AI video generator, no time limits |
| 8188 | ComfyUI | Advanced AI workflows |
| 7860 | Stable Diffusion A1111 | Full Suite only |
| 8888 | JupyterLab | Dev Tools only |
| 8080 | VS Code | Dev Tools only |

**SSH tunnel (optional, private access only):**
```bash
ssh -L 9080:127.0.0.1:9080 shadeform@<SERVER_IP>
# then open http://localhost:9080
```

Product doc: `AGH-CREATIVE-SUITE-PRODUCT.md`

---

## Related

- [`../examples/desktop-user.yaml`](../examples/desktop-user.yaml) —
  the base config used in this tutorial
- [`../examples/desktop-sway.yaml`](../examples/desktop-sway.yaml) —
  Sway (Wayland) variant for tiling-WM users
- [`../examples/desktop-openbox.yaml`](../examples/desktop-openbox.yaml)
  — minimal Openbox setup, ~1 GB RAM instead of 4 GB
- [`../examples/desktop-web.yaml`](../examples/desktop-web.yaml) —
  web-first variant: Chrome as session (no XFCE bar)
- [`../examples/cloud-desktop.yaml`](../examples/cloud-desktop.yaml)
  — desktop auto-published to `*.envpod.cloud` (Premium)
- [`../docs/DEVICES.md`](../docs/DEVICES.md) — display / audio / GPU
  passthrough options
- [`CE-TELEMETRY.md`](CE-TELEMETRY.md) — what CE records in
  `audit.log` (this desktop pod's events too — DNS queries, mounts,
  every action the runtime took)
