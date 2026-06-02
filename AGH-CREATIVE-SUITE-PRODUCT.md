# AGH Creative Suite — Product Document

**Version:** 1.0  
**Date:** 2026-06-01  
**URL:** https://aghcloud.ai/packages/creative-suite

---

## What Is It?

AGH Creative Suite is a one-command setup that turns a rented GPU server into a full AI creative workstation — accessible from any browser, anywhere, with no software to install on your laptop.

You rent an H100 GPU on Shadeform. You run one command. In 20–90 minutes (depending on which apps you pick), you get a full Linux desktop in your browser with every AI creative tool pre-installed, pre-configured, and ready to use.

---

## The Core Problem It Solves

Every commercial AI tool has limits:

| Tool | Limitation |
|---|---|
| Gemini Video | 8 seconds per generation |
| RunwayML | 4–10 seconds, watermarks on free tier |
| Sora | Limited access, no API |
| ElevenLabs | Monthly character cap |
| Midjourney | Per-image credits |

With AGH Creative Suite, you own the GPU. There are no limits — generate a 2-minute video, 100 images, hours of music. The only cost is the GPU rental time.

---

## Who Is It For?

- **Video creators** who need longer AI-generated clips than commercial tools allow
- **Creative studios** that want a reproducible, on-demand AI workstation without managing infrastructure
- **Editors** who want AI upscaling, frame interpolation, and voice generation in one place
- **Developers / researchers** who want full control over open-source AI models

---

## What You Get

### Desktop Environment
Full XFCE Linux desktop in your browser. No VNC client needed — just open a URL.

### Always Installed (Every Package)

| App | Port | What It Does |
|---|---|---|
| **Fooocus** | 7865 | Midjourney-style image generation — type prompt, get image, zero config |
| **ComfyUI** | 8188 | Advanced AI workflow hub — node editor for image, video, and audio pipelines |
| **Chrome** | — | Pre-installed browser for accessing all web UIs from the desktop |
| **GIMP** | — | Full image editor (Photoshop equivalent) |
| **Krita** | — | Digital painting and illustration |
| **Kdenlive** | — | Professional video editor (non-linear) |
| **Audacity** | — | Audio recording and editing |
| **Inkscape** | — | Vector graphics (Illustrator equivalent) |
| **FFmpeg** | — | Video/audio conversion and processing |
| **Blender** | — | 3D modeling, animation, rendering |
| **WhisperX** | — | Speech-to-text transcription (any language) |

### Optional Packages

#### Starter Package (~40GB, ~20 min)
Best for image generation and short video work.
- **FLUX model** (via ComfyUI) — state-of-the-art image generation, better than Midjourney for many use cases
- **Wan2.1** (port 7870, browser UI) — AI video generation up to 2+ minutes, no watermarks, no time limits
- **Real-ESRGAN + RIFE** — AI upscaling (4x resolution) + frame interpolation (24fps → 60fps)

#### Creator Package (~140GB, ~60 min)
Everything in Starter, plus:
- **HunyuanVideo** — highest quality open-source text-to-video, best for cinematic output
- **MusicGen** — generate background music from a text prompt ("epic orchestral", "lo-fi chill")
- **Demucs** — separate any song into vocals, drums, bass, instruments (stems)
- **Bark TTS** — AI voice generation in any style

#### Full Suite (~170GB, ~90 min)
Everything, including:
- **Stable Diffusion WebUI (A1111)** — full SD ecosystem with ControlNet, IP-Adapter, LoRA
- **LTX-Video** — ultra-fast video generation for quick prototypes
- **CogVideoX-5B** — alternative video model for different visual styles
- **OpenVoice** — voice cloning
- **VS Code + JupyterLab** — for developers

---

## Access Methods

### Inside the Desktop (Zero Setup)
Open Chrome in the XFCE desktop — it opens the **AGH Portal** automatically at `http://localhost:9080`. Every service is one click away. No SSH, no configuration.

### Public URLs (Shareable, No SSH)
After setup, each service gets its own public URL printed to the terminal:

```
Portal:           https://xxxx.trycloudflare.com   ← start here
Desktop:          https://yyyy.trycloudflare.com/vnc.html
Fooocus (images): https://zzzz.trycloudflare.com
Wan2.1 (video):   https://aaaa.trycloudflare.com
ComfyUI:          https://bbbb.trycloudflare.com
```

Share any URL directly. The portal page also lists all public URLs so you can bookmark one link and access everything.

### SSH Tunnel (Optional, Private)
Only needed if you want private access without public URLs:
```bash
ssh -L 9080:127.0.0.1:9080 shadeform@<YOUR_SERVER_IP>
```
Then open `http://localhost:9080` — the portal links to everything else.

---

## Service Ports

| Service | Port | URL | Notes |
|---|---|---|---|
| Desktop (XFCE via noVNC) | 6080 | http://localhost:6080/vnc.html | Full Linux desktop |
| **Fooocus** | **7865** | **http://localhost:7865** | **Midjourney-style — always installed** |
| **Wan2.1 Video** | **7870** | **http://localhost:7870** | **AI video generator — no time limits** |
| ComfyUI | 8188 | http://localhost:8188 | Advanced AI workflows |
| Stable Diffusion A1111 | 7860 | http://localhost:7860 | Optional (Full Suite) |
| JupyterLab | 8888 | http://localhost:8888 | Optional (Dev Tools) |
| VS Code | 8080 | http://localhost:8080 | Optional (Dev Tools) |

---

## How to Provision (One Command)

```bash
wget -qO setup_creative_suite.sh https://raw.githubusercontent.com/niksresearch/agh-installations/main/setup_creative_suite.sh && sudo bash setup_creative_suite.sh
```

**What happens:**
1. Script asks for a desktop password
2. Shows bundle menu — pick Starter, Creator, Full Suite, or Custom
3. Installs everything automatically
4. Prints public URL + all service ports when done

**Prerequisites:**
- Shadeform GPU VM (H100 recommended, works on A100/A40)
- Ubuntu 22.04
- That's it

---

## Real-World Use Cases

### Use Case 1 — AI Video Campaign
A marketing team needs a 90-second product video with AI-generated visuals.
- Generate scenes with HunyuanVideo (no 8s limit)
- Upscale to 4K with Real-ESRGAN
- Generate background music with MusicGen
- Voice narration with Bark TTS
- Edit everything together in Kdenlive
- **Cost:** ~$5–15 GPU rental vs $200+/month in commercial tools

### Use Case 2 — Content Creator Workflow
A YouTube creator wants consistent AI art for thumbnails and channel art.
- Generate images with FLUX via ComfyUI
- Edit in GIMP / Krita
- Use ControlNet (in A1111) for consistent character styles
- **Cost:** Per-session GPU rental vs Midjourney subscription

### Use Case 3 — Music Producer
Producer wants AI tools without subscription lock-in.
- Separate stems from any track with Demucs
- Generate background music from text prompt with MusicGen
- Edit audio in Audacity
- **Cost:** One-time GPU rental, no per-track fees

---

## Why H100 / H200?

| GPU | VRAM | HunyuanVideo (2min video) | FLUX image |
|---|---|---|---|
| H200 | 141GB | ~4 min | ~6 sec |
| H100 | 80GB | ~8 min | ~10 sec |
| A100 | 40/80GB | ~12 min | ~15 sec |
| A40 | 48GB | ~20 min | ~20 sec |
| Consumer GPU (3090) | 24GB | ❌ not enough VRAM | ~60 sec |

H100/H200's large VRAM is why long video generation is possible — commercial tools cap at 8 seconds precisely because they can't allocate 80GB+ per user request. H200 with 141GB VRAM can run multiple large models simultaneously.

---

## Pricing Model (Shadeform)

| GPU | Price | 1 hour session | Full day |
|---|---|---|---|
| H200 SXM5 | ~$4.00/hr | $4.00 | $96 |
| H100 SXM5 | ~$2.50/hr | $2.50 | $60 |
| H100 PCIe | ~$1.80/hr | $1.80 | $43 |

Compare: RunwayML Gen-3 at $0.05/second = $3/minute of video. One 2-minute video = $6. On H100/H200, you can generate dozens of 2-minute videos per hour for $2.50–$4.00 total.

---

## Technical Foundation

Built on:
- **envpod CE** — secure pod runtime with overlay filesystem and network isolation
- **nsenter** — namespace entry for installing packages without seccomp restrictions
- **cloudflared** — free Cloudflare tunnel for public URL access
- All apps installed via **Python venvs** at `/opt/` — isolated, reproducible, no system conflicts

GitHub: https://github.com/niksresearch/agh-installations

---

## Current Limitations

| Limitation | Status |
|---|---|
| GPU passthrough via envpod CE | Workaround via nsenter (works) |
| Persistent storage across VM destroy | Manual — need to save work before stopping VM |
| Auth on public URL | VNC password only — Cloudflare Access planned |
| Multi-user | Single desktop per VM — fleet mode planned |
| Windows/macOS host | Not supported — Linux VMs only |

---

## Roadmap

1. **Golden image** — pre-baked Shadeform snapshot so boot time is <5 min with all models ready
2. **Cloudflare Access auth** — Google/GitHub SSO on public URL
3. **Multi-user fleet** — one VM, multiple isolated desktops
4. **Web dashboard** — spin up / manage creative VMs from a browser UI
5. **Model library** — curated model downloads with one-click install inside ComfyUI
