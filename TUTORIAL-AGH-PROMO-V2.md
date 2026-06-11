# AGH Creative Suite — Director's Cut Promo (Bundle 2 "Creator")

**The story:** This is the *premium* version of our self-made promo. Same idea as the
Bundle 1 promo — "we made this using the thing we're promoting" — but it uses every
upgrade in **Bundle 2 "Creator"** and pulls the **real AGH brand assets** straight from
`aghcloud.ai`.

No external tools. No agency. No subscriptions.
One H100. Real branding. FLUX images. 4K upscale. Two video engines. A spoken voiceover.

The fully automated version is `demo_creative_suite_v2.sh`. This doc explains what it
does step by step, and how to drive the same pipeline by hand from the portal.

---

## Bundle 1 vs Bundle 2 — what changed

| Capability | Bundle 1 promo (`demo_creative_suite.sh`) | Bundle 2 Director's Cut (`demo_creative_suite_v2.sh`) |
|---|---|---|
| Branding | Text cards only | **Real AGH logo + banner** fetched from `aghcloud.ai` |
| Images | SD 1.5 / SDXL (ComfyUI) | **FLUX** (ComfyUI) → SDXL → SD 1.5 auto-fallback |
| Sharpening | — | **Real-ESRGAN x4** upscale of every frame |
| Video | Wan2.1 | **Wan2.1 + HunyuanVideo** (AGH Video Studio) |
| Voice | — | **Bark TTS** spoken narration |
| Music | MusicGen | MusicGen |
| Assembly | FFmpeg | FFmpeg with logo watermark + voiceover/music ducking |

Bundle 2 = `flux wan21 hunyuan musicgen bark esrgan`. Everything the script needs is
installed by `setup_creative_suite.sh` when provisioned with `BUNDLE=2`.

---

## What we're building

A ~70-second branded promo structured as:

| Segment | Tool | Description |
|---|---|---|
| 0. Brand fetch | curl | Pull the official `agh-icon.png` + `og-image.png` from the live site |
| 1. Intro | FFmpeg | Real banner, AGH logo overlay, tagline, fade in/out |
| 2. Image gen | ComfyUI / FLUX | 6 brand images generated live |
| 3. Upscale | Real-ESRGAN | Each frame sharpened x4 → crisp Ken-Burns slideshow |
| 4a. Video | Wan2.1 14B | Futuristic studio clip |
| 4b. Video | HunyuanVideo | Neon AI-gallery fly-through (richer motion) |
| 5. Voiceover | Bark TTS | Spoken narration over the reel |
| 6. Music | MusicGen | Original 75s cinematic score |
| 7. Assembly | FFmpeg | Logo watermark, voiceover full, music ducked under it |

---

## Real brand assets

The site exposes exactly two production images we can reuse:

- `https://aghcloud.ai/agh-icon.png` — the AGH logo, 548×440 **RGBA (transparent)** —
  perfect as an overlay watermark and end-card mark.
- `https://aghcloud.ai/og-image.png` — the social banner, 1408×768 — used as the
  intro background.

The script fetches both, validates they are real PNGs, and falls back to generated
text cards if the site is unreachable.

```bash
curl -sL https://aghcloud.ai/agh-icon.png -o brand/agh-icon.png
curl -sL https://aghcloud.ai/og-image.png -o brand/og-image.png
```

---

## Run it (automated)

Provision the H100 with Bundle 2:

```bash
BUNDLE=2 VNC_PASS=yourpass HF_TOKEN=hf_xxx sudo bash setup_creative_suite.sh
```

> `HF_TOKEN` is only needed for FLUX (gated). Without it the script still runs and
> auto-falls back to the free SDXL checkpoint for images.

Then make the promo:

```bash
sudo nohup bash demo_creative_suite_v2.sh > /ephemeral/demo_v2.log 2>&1 &
tail -f /ephemeral/agh-promo-v2/demo.log     # clean progress
tail -f /ephemeral/agh-promo-v2/demo-debug.log   # full command output
```

Final output:

```
/ephemeral/agh-promo-v2/AGH_Creative_Suite_Promo_DirectorsCut.mp4
```

The script prints the exact `scp` command to pull it to your laptop when done.

---

## Step-by-step (manual, from the portal)

### Step 2 — Images with FLUX (ComfyUI, port 8188)

Open the portal → **ComfyUI**. FLUX is the default if Bundle 2 downloaded it
(`unet/flux1-schnell.safetensors`, `clip/`, `vae/ae.safetensors`). Use these prompts
(16:9):

1. Futuristic AI creative workstation, holographic screens, blue/purple, cinematic.
2. Confident African creative professional at multiple screens, golden hour, aspirational.
3. Abstract AI creativity — neural networks forming art, electric blue particles, 8K.
4. H100 GPU chip glowing neon blue, macro, chrome and silicon, dramatic lighting.
5. Glowing map of Africa as a circuit board, data centers lighting up, cyan, 8K.
6. Creative studio at night, screens glowing with AI art, cinematic wide shot.

FLUX schnell needs only ~4 steps, `cfg 1.0`, sampler `euler`, scheduler `simple`.

### Step 3 — Upscale (Real-ESRGAN)

In a terminal:

```bash
source /opt/enhancement-env/bin/activate
# RealESRGANer + RealESRGAN_x4plus.pth → 2x outscale per frame
```

The script applies a torchvision shim (newer torchvision removed
`functional_tensor`, which `basicsr` still imports) before upscaling, then builds a
Ken-Burns zoom slideshow from the sharpened frames.

### Step 4 — Video (two engines)

- **Wan2.1** — `/opt/Wan2.1`, `wan21-env`. CLI `generate.py --task t2v-14B`.
- **HunyuanVideo** — AGH Video Studio diffusers venv `/opt/agh-video-env`. Either use
  the Gradio UI on **port 7871** or call the pipeline directly (`HunyuanVideoPipeline`,
  `enable_model_cpu_offload`, `vae.enable_tiling`). HunyuanVideo is heavy — expect the
  longest single step in the run.

### Step 5 — Voiceover (Bark, port-less CLI)

```bash
source /opt/voice-env/bin/activate
# bark.generate_audio(line) per short line, concat with 0.4s gaps → voiceover.wav
```

Keep each narration line short (Bark truncates past ~13s) and spell acronyms out
(`A G H`, `G P U`) so they read naturally.

### Step 6 — Music (MusicGen)

```bash
source /opt/audio-env/bin/activate
# MusicGen.get_pretrained('melody'), duration=75 → music.wav (32kHz)
```

### Step 7 — Assembly (FFmpeg)

- Normalize every segment to `1280x720 @ 24fps yuv420p` MPEG-TS, then `concat`.
- Overlay the **real logo** top-right as a persistent watermark.
- Mix audio: voiceover at full volume, music ducked to ~0.16 underneath
  (`amix`, voiceover `apad`-padded so it runs the length of the video, `-shortest`).

---

## Notes & gotchas

- **FLUX is gated.** Accept the license at
  `https://huggingface.co/black-forest-labs/FLUX.1-schnell` and pass `HF_TOKEN`. The
  script silently falls back to SDXL if FLUX weights aren't present.
- **HunyuanVideo is slow** and downloads a large model on first use (cached under
  `${AGH_MODELS}/hf-cache`). It's the long pole of the run.
- **Bark / MusicGen** download their models on first call if `setup` didn't preload
  them; subsequent runs are fast.
- Outputs live in `/ephemeral/agh-promo-v2/` (or `${AGH_DATA}/agh-promo-v2/`), separate
  from the Bundle 1 promo's `agh-promo/` so the two never clobber each other.

---

*Made entirely with AGH Creative Suite — Bundle 2 "Creator". You are watching the product.*
