# AGH Creative Suite — Commands & Parameters Reference

Single source for every command: provision, verify, smoke-test, generate, and run
the promo demos. All scripts live in `niksresearch/agh-installations` and are pulled
with `wget` from the `main` branch raw URLs.

```
RAW=https://raw.githubusercontent.com/niksresearch/agh-installations/main
```

| Script | Purpose |
|---|---|
| `install_gpu_drivers.sh` | NVIDIA drivers + envpod + pod templates (run once per fresh VM) |
| `setup_creative_suite.sh` | Provision a bundle (desktop + AI apps + models) |
| `verify_bundle.sh` | Check every component a bundle should have is present + running |
| `smoke_test.sh` | Tiny per-tool generation test (lite/heavy) before the full demo |
| `benchmark.sh` | Per-model performance sheet — time, peak VRAM, output spec, cost, tokens |
| `demo_creative_suite.sh` | Bundle 1 promo (real AGH branding + images + Wan2.1 + music) |
| `demo_creative_suite_v2.sh` | Bundle 2 "Director's Cut" promo (FLUX + ESRGAN + Hunyuan + Bark) |

---

## 1. Provision a VM

### Step 1 — drivers + envpod (once per fresh VM)
```bash
wget -qO agh_pre_installer.sh $RAW/install_gpu_drivers.sh && sudo bash agh_pre_installer.sh
```

### Step 2 — setup a bundle
```bash
wget -qO setup_creative_suite.sh $RAW/setup_creative_suite.sh

# Unattended (recommended): set BUNDLE + VNC_PASS. HF_TOKEN optional.
sudo BUNDLE=2 VNC_PASS=yourpass HF_TOKEN=hf_xxx nohup bash setup_creative_suite.sh > setup.log 2>&1 &
tail -f setup.log
```

Interactive (no `BUNDLE` env) → menu picks the bundle.

#### Setup environment variables

| Var | Required | Default | Meaning |
|---|---|---|---|
| `BUNDLE` | for unattended | — | `1` Starter, `2` Creator, `3` Full Suite |
| `VNC_PASS` | for unattended | — | Desktop VNC password (min 6 chars) |
| `HF_TOKEN` | optional | — | HuggingFace token. Needed for **FLUX** (gated). Without it → SDXL fallback |
| `FLUX_VARIANT` | optional | `schnell` | `schnell` (4-step, fast) or `dev` (higher quality, gated) |

#### Bundles

| Bundle | `SELECTED_APPS` | Size | Time |
|---|---|---|---|
| 1 Starter | `flux wan21 esrgan` | ~40GB | ~20min |
| 2 Creator | `flux wan21 hunyuan musicgen bark esrgan` | ~140GB | ~60min |
| 3 Full | `flux a1111 hunyuan wan21 ltx cogvideo esrgan musicgen bark devtools` | ~170GB | ~90min |

Always installed (all bundles): GIMP, Krita, Kdenlive, Audacity, Inkscape, **ComfyUI**,
FFmpeg, Blender, MusicGen, Chrome.

---

## 2. Verify a bundle

Confirms each expected component is installed and shows which services are running.

```bash
wget -qO verify_bundle.sh $RAW/verify_bundle.sh
sudo bash verify_bundle.sh 1     # Starter
sudo bash verify_bundle.sh 2     # Creator
sudo bash verify_bundle.sh 3     # Full Suite
```

Output: per-component `✓ present / ✗ missing`, running services `● listening / ○ down`,
GPU memory, and a `PASS` / `INCOMPLETE` verdict. Exit code `0` = ready.

### Expected components per bundle

| Component | B1 | B2 | B3 |
|---|:--:|:--:|:--:|
| FFmpeg, Blender, ComfyUI :8188, MusicGen, image checkpoint | ✓ | ✓ | ✓ |
| Wan2.1 (`/opt/Wan2.1`, :7870) | ✓ | ✓ | ✓ |
| Real-ESRGAN (`RealESRGAN_x4plus.pth`) | ✓ | ✓ | ✓ |
| FLUX weights (else SDXL fallback) | ✓ | ✓ | ✓ |
| HunyuanVideo (`/opt/agh-video-env`, :7871) | — | ✓ | ✓ |
| Bark TTS (`/opt/voice-env`) | — | ✓ | ✓ |
| A1111 (`/opt/stable-diffusion-webui`, :7860) | — | — | ✓ |
| LTX + CogVideoX (Video Studio :7871) | — | — | ✓ |
| Dev tools (code-server :8080, Jupyter :8888) | — | — | ✓ |

---

## 3. Smoke test (per-tool generation)

Runs a tiny job against each tool and logs PASS/FAIL + time. Do this **before** the
full demo so you catch a broken tool early.

```bash
wget -qO smoke_test.sh $RAW/smoke_test.sh
```

### Modes & arguments

```
sudo bash smoke_test.sh [lite|heavy] [test names | all]
```

- **Arg 1** (optional): `lite` (default) or `heavy` — size/length profile
- **Remaining args**: test names, `all` (Bundle 1/2 tools), or `b3` (all tools incl. Bundle 3).
  Default (none) = `image upscale music voice`
- **Test names**: `image upscale music voice wan21 hunyuan ltx cogvideo a1111`
- Tools not installed in the current bundle are **SKIPPED** (○), not failed — so `b3` on a
  Bundle 2 VM cleanly skips `ltx`/`cogvideo`/`a1111`.

| Parameter | lite | heavy |
|---|---|---|
| Image | 512×512, 12 steps | 1280×720, 30 steps |
| Music | 5s | 120s (2-min track) |
| Wan2.1 | 81 frames, 10 steps | 161 frames, 40 steps |
| HunyuanVideo | 25 frames, 512×320, 15 steps | 129 frames, 960×544, 30 steps |
| LTX-Video (B3) | 49 frames, 20 steps | 121 frames, 30 steps |
| CogVideoX-5B (B3) | 49 frames, 20 steps | 49 frames, 50 steps |
| A1111 (B3) | 512×512, 12 steps | 1280×720, 30 steps |

### Examples
```bash
sudo bash smoke_test.sh                 # lite, core 4 (image upscale music voice)
sudo bash smoke_test.sh lite all        # lite, Bundle 1/2 tools (+ wan21 hunyuan)
sudo bash smoke_test.sh heavy all       # big sizes + long clips, Bundle 1/2 tools
sudo bash smoke_test.sh lite b3         # lite, ALL tools incl. Bundle 3 (ltx cogvideo a1111)
sudo bash smoke_test.sh heavy b3        # full Bundle 3 real-load run
sudo bash smoke_test.sh heavy image     # just a 720p image
```

### Outputs & log
```
/tmp/agh-test/smoke.log     # clean summary, per-test timing + total time
/tmp/agh-test/<name>.err    # stderr for any failed test
/tmp/agh-test/img.png img_2x.png music.wav voice.wav wan.mp4 hunyuan.mp4
```

Notes:
- `upscale` reuses `image`'s output — run `image` first (default order does this).
- Heavy video tests run **one at a time** — never two GPU jobs at once.
- Bark / Hunyuan download their model on first run — first pass is slower.

---

## 3b. Benchmark (performance / spec sheet)

`benchmark.sh` measures each model's **time, peak VRAM, output spec, throughput, and
derived cost** — the numbers you publish on a spec/sales sheet. Chat models also get
prompt/completion **tokens** + tokens/sec (image/video/audio have no tokens; their
units are steps/frames/seconds).

```bash
wget -qO benchmark.sh $RAW/benchmark.sh
sudo bash benchmark.sh                        # all installed creative models
sudo bash benchmark.sh image video            # only these groups
sudo GPU_RATE=2.50 bash benchmark.sh          # fill the cost column ($/GPU-hour)
sudo CHAT_URL=http://127.0.0.1:8000/v1 CHAT_MODEL=llama3 bash benchmark.sh chat
```

- **Groups:** `image video audio upscale chat` (default: all)
- **Config env:** `GPU_RATE` ($/GPU-hour → cost column), `CHAT_URL` + `CHAT_MODEL`
  (+ optional `CHAT_KEY`) for the chat benchmark against an OpenAI-compatible endpoint
  (e.g. the AGH LLM suite gateway).
- Uninstalled tools are skipped. Video models run one at a time. First run of
  Hunyuan/CogVideoX/LTX downloads its model (slower).

**Outputs:**
```
/tmp/agh-bench/results.csv    # machine-readable
/tmp/agh-bench/results.md     # sales-ready Markdown table (GPU, per-model rows, cost)
```

Representative jobs benchmarked: FLUX/SDXL 1024² image (25 steps), Wan2.1 720p 81f,
LTX 97f, CogVideoX 49f, Hunyuan 61f, Real-ESRGAN 4×, MusicGen 30s, Bark 1 sentence,
and (if configured) a 150-word chat completion.

---

## 4. Run the promo demos

### Bundle 1 — `demo_creative_suite.sh`
Real AGH branding + ComfyUI images + Blender logo + Wan2.1 + MusicGen.
```bash
wget -qO demo_creative_suite.sh $RAW/demo_creative_suite.sh
sudo bash demo_creative_suite.sh
tail -f /ephemeral/agh-promo/demo.log
# final: /ephemeral/agh-promo/AGH_Creative_Suite_Promo.mp4
```

### Bundle 2 — `demo_creative_suite_v2.sh`
FLUX images + Real-ESRGAN 4K + Wan2.1 + HunyuanVideo + Bark voiceover + MusicGen.
```bash
wget -qO demo_creative_suite_v2.sh $RAW/demo_creative_suite_v2.sh
sudo bash demo_creative_suite_v2.sh
tail -f /ephemeral/agh-promo-v2/demo.log
# final: /ephemeral/agh-promo-v2/AGH_Creative_Suite_Promo_DirectorsCut.mp4
```

Both self-background and write two logs: `demo.log` (clean steps) + `demo-debug.log`
(full command output). `<DATA_DIR>` = `/ephemeral` on Shadeform, else `/opt`.

---

## 5. Service ports

| Port | Service | Bundles |
|---|---|---|
| 9080 | AGH Portal (start here) | all |
| 6080 | Desktop (noVNC) | all |
| 8188 | ComfyUI (image gen) | all |
| 7870 | Wan2.1 Video | all (Wan2.1) |
| 7871 | AGH Video Studio (Hunyuan/LTX/CogVideoX) | 2, 3 |
| 7860 | Stable Diffusion A1111 | 3 |
| 8888 | JupyterLab | 3 (devtools) |
| 8080 | VS Code (code-server) | 3 (devtools) |

Quick "what's running" check:
```bash
for p in 8188:ComfyUI 7870:Wan2.1 7871:VideoStudio 7860:A1111 8888:Jupyter 8080:VSCode 9080:Portal; do
  port=${p%%:*}; name=${p##*:};
  ss -ltn 2>/dev/null | grep -q ":$port " && echo "● $name (:$port) UP" || echo "○ $name (:$port) down";
done
```

---

## 6. Long video (beyond a single clip)

No open model produces a coherent **single-shot 2-minute** video on one H100 — T2V
models cap at ~5–10s before VRAM and motion drift break down. To get longer:

1. **Clip chaining (image-to-video):** generate a clip, feed its last frame as the
   init image for the next, repeat. Wan2.1 + Hunyuan support i2v. Closest to "continuous".
2. **Multi-clip assembly** ← what the demos do. Many short clips + slideshow + cards +
   audio, stitched in FFmpeg/Kdenlive → 2+ minutes, no drift. Recommended.
3. Research long-video methods (StreamingT2V / FreeNoise) — not bundled, extra setup.
4. Commercial cloud (Kling, Runway, Sora) — off-box, paid, not part of self-hosted AGH.

`smoke_test.sh heavy` gives the longest **feasible single clip** (~10s hi-res) for timing.

---

## 7. Download outputs to your laptop

```bash
# final promo
scp shadeform@<SERVER_IP>:/ephemeral/agh-promo-v2/AGH_Creative_Suite_Promo_DirectorsCut.mp4 ~/Desktop/

# whole output folder
scp -r shadeform@<SERVER_IP>:/ephemeral/agh-promo-v2/ ~/Desktop/agh-promo-v2/

# smoke-test artifacts
scp -r shadeform@<SERVER_IP>:/tmp/agh-test/ ~/Desktop/agh-test/
```
Each demo also prints the exact `scp` command (auto-detects IP + SSH key) when done.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Step 2 images all "ComfyUI rejected prompt" in 0s | No checkpoint in `comfyui/checkpoints` | Setup now downloads SDXL/SD1.5 via `hf_hub_download`. Confirm with `verify_bundle.sh`. |
| FLUX not used | `HF_TOKEN` absent (gated model) | Pass `HF_TOKEN=hf_xxx` at setup, or accept SDXL fallback. |
| Wan2.1 / video step OOM or hang | GPU already holds another model | Run one GPU job at a time; check `nvidia-smi`. Wan2.1 14B uses ~73GB. |
| HunyuanVideo first run very slow | Downloads model on first use | One-time; cached in `${AGH_MODELS}/hf-cache` after. |
| Brand assets not fetched | Pod has no outbound HTTPS | Demo auto-falls back to text cards — not fatal. |
| `whisperx-run` fails | `/opt/whisperx-env` not created by setup | Known gap; WhisperX not used by any demo. |

---

*Desktop / VNC / envpod details: see [`TUTORIAL-DESKTOP-VNC.md`](TUTORIAL-DESKTOP-VNC.md).*
*Per-step promo walkthroughs: [`TUTORIAL-AGH-PROMO.md`](TUTORIAL-AGH-PROMO.md) (Bundle 1),
[`TUTORIAL-AGH-PROMO-V2.md`](TUTORIAL-AGH-PROMO-V2.md) (Bundle 2).*
