# AGH Creative Suite — How We Made Our Own Promo Video

**The story:** This promotional video for AGH Creative Suite was created entirely *using* AGH Creative Suite.

No external tools. No agency. No subscriptions.  
One H100. One hour. ~$2.50.

---

## What We're Building

A ~70-second branded promo, assembled automatically by `demo_creative_suite.sh`:

| Segment | Tool | Description |
|---|---|---|
| 0. Brand fetch | curl | Pull the real `agh-icon.png` + `og-image.png` from `aghcloud.ai` |
| 1. Branded intro | FFmpeg | Real banner background + real logo overlay + tagline, fade in/out |
| 2. Image gen | ComfyUI (port 8188) | 6 brand images generated live (SDXL → SD1.5 auto-fallback) → slideshow |
| 3. Logo 3D reveal | Blender | AGH logo 3D reveal, glowing orbital rings (headless EEVEE) |
| 4. AI video | Wan2.1 14B | Two cinematic clips — futuristic studio + AI-generation reveal |
| 5. Music | MusicGen | Original ~90s cinematic score |
| 6. Assembly | FFmpeg | Section cards, real-logo watermark, music, reliable TS concat |

> Bundle 1 "Starter" = `flux wan21 esrgan`. Images run on whatever checkpoint
> actually downloaded (SDXL preferred, SD1.5 fallback) — the script auto-detects.

---

## Step 1 — Generate Brand Images (ComfyUI)

Open portal → click **ComfyUI** → `http://localhost:8188`

The automated script submits these via the ComfyUI API (`POST /prompt`) using the
checkpoint that actually downloaded — SDXL (`sd_xl_base_1.0.safetensors`) if present,
else SD 1.5. To drive it by hand, load a basic txt2img graph and use these 6 prompts
(16:9, ~25 steps, cfg 7.5, sampler euler). Each takes ~20–60s on the H100.

### Image 1 — `agh_workstation`
```
A sleek futuristic AI creative workstation glowing with blue and purple light, 
multiple holographic screens showing AI-generated artwork, dark minimal setup, 
cinematic lighting, ultra detailed
```
Settings: Realistic, 16:9

### Image 2 — `agh_creator`
```
A confident creative professional in front of multiple screens showing stunning 
AI-generated videos and images, golden hour light, inspired expression, 
cinematic aspirational
```
Settings: Realistic, 16:9

### Image 3 — `agh_abstract_ai`
```
Abstract visualization of artificial intelligence creativity, flowing neural 
networks forming beautiful art, electric blue and purple particles, 
deep space background, 8K
```
Settings: Realistic, 16:9

### Image 4 — `agh_gpu_power`
```
An H100 GPU chip glowing with neon blue light, futuristic close-up macro shot, 
cinematic dramatic lighting, chrome and silicon textures
```
Settings: Realistic, 16:9

### Image 5 — `agh_brand`
```
The letters AGH formed from glowing light particles and energy trails against 
dark background, futuristic logo, electric blue and cyan, cinematic 8K
```
Settings: Realistic, 16:9

### Image 6 — `agh_no_limits`
```
A creative studio at night, screens glowing with AI-generated art, text NO LIMITS 
visible, inspiring atmosphere, cinematic wide shot
```
Settings: Realistic, 16:9

**Save all 6** to `<DATA_DIR>/agh-promo/images/` (the script writes them there automatically — ComfyUI prefixes each filename with the name above).

---

## Step 2 — Generate Promo Videos (Wan2.1)

Open portal → click **Wan2.1 Video** → `http://localhost:7870`

The automated script generates **two** clips (`t2v-14B`, 1280×720, guidance 6.0),
then trims them for the reel.

### Clip 1 — `wan21_workspace.mp4` (futuristic studio, trimmed to 15s)
```
A futuristic AI creative studio. Holographic screens display stunning AI-generated 
artwork being created in real-time. Glowing particle effects flow between screens. 
Camera slowly pushes forward through the workspace. Deep blue and purple lighting. 
Cinematic, photorealistic, ultra smooth motion, 4K commercial quality.
```
- `--sample_steps 50` | `--sample_guide_scale 6.0`

### Clip 2 — `wan21_ai_gen.mp4` (AI-generation reveal, trimmed to 10s)
```
Abstract visualization of an AI generating an image, pixels assembling from noise 
into a stunning photorealistic landscape, time-lapse style, particle effects, 
glowing neural pathways, electric blue light, dramatic reveal, cinematic 4K.
```
- `--sample_steps 40` | `--sample_guide_scale 6.0`

Each generation: ~8-15 min on H100. Wan2.1 14B uses ~73GB VRAM — do not run image
generation (ComfyUI) at the same time.

**Save to:** `<DATA_DIR>/agh-promo/videos/`

---

## Step 3 — AGH Logo 3D Reveal (Blender)

Open **Blender** from XFCE desktop → **Scripting** tab → paste this script:

```python
import bpy, math

# ── Clear scene ──────────────────────────────────────────────────────────────
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete()

# ── Camera ───────────────────────────────────────────────────────────────────
bpy.ops.object.camera_add(location=(0, -12, 2))
cam = bpy.context.object
cam.rotation_euler = (math.radians(80), 0, 0)
bpy.context.scene.camera = cam

# ── AGH text object ──────────────────────────────────────────────────────────
bpy.ops.object.text_add(location=(0, 0, 0))
txt = bpy.context.object
txt.data.body = "AGH"
txt.data.align_x = "CENTER"
txt.data.size = 2.0
txt.data.extrude = 0.3
txt.data.bevel_depth = 0.05

# Glow material
mat = bpy.data.materials.new("AGHMat")
mat.use_nodes = True
nodes = mat.node_tree.nodes
links = mat.node_tree.links
nodes.clear()
emission = nodes.new("ShaderNodeEmission")
emission.inputs["Color"].default_value = (0.0, 0.6, 1.0, 1.0)  # electric blue
emission.inputs["Strength"].default_value = 3.0
output = nodes.new("ShaderNodeOutputMaterial")
links.new(emission.outputs["Emission"], output.inputs["Surface"])
txt.data.materials.append(mat)

# Convert to mesh for better render
bpy.ops.object.convert(target='MESH')
txt.location = (-2.8, 0, 0)

# ── Keyframes: scale reveal ───────────────────────────────────────────────────
txt.scale = (0, 0, 0)
txt.keyframe_insert("scale", frame=1)
txt.scale = (1.0, 1.0, 1.0)
txt.keyframe_insert("scale", frame=30)

# Rotation during reveal
txt.rotation_euler = (0, math.radians(90), 0)
txt.keyframe_insert("rotation_euler", frame=1)
txt.rotation_euler = (0, 0, 0)
txt.keyframe_insert("rotation_euler", frame=30)

# Hold steady, then slow spin
txt.keyframe_insert("rotation_euler", frame=60)
txt.rotation_euler = (0, math.radians(15), 0)
txt.keyframe_insert("rotation_euler", frame=120)

# ── Orbiting light rings ──────────────────────────────────────────────────────
for i, (col, rad, tilt) in enumerate([
    ((0.0, 0.6, 1.0, 1.0), 4.5, 75),
    ((0.6, 0.1, 1.0, 1.0), 5.5, 45),
    ((0.0, 1.0, 0.8, 1.0), 6.5, 20),
]):
    bpy.ops.mesh.primitive_torus_add(
        major_radius=rad, minor_radius=0.04,
        location=(0, 0, 0),
        rotation=(math.radians(tilt), math.radians(i*30), 0)
    )
    ring = bpy.context.object
    rm = bpy.data.materials.new(f"Ring{i}")
    rm.use_nodes = True
    rn = rm.node_tree.nodes; rn.clear()
    re = rn.new("ShaderNodeEmission")
    re.inputs["Color"].default_value = col
    re.inputs["Strength"].default_value = 2.5
    ro = rn.new("ShaderNodeOutputMaterial")
    rm.node_tree.links.new(re.outputs["Emission"], ro.inputs["Surface"])
    ring.data.materials.append(rm)
    # Animate: appear + spin
    ring.scale = (0, 0, 0)
    ring.keyframe_insert("scale", frame=max(1, 20 - i*5))
    ring.scale = (1, 1, 1)
    ring.keyframe_insert("scale", frame=40 + i*5)
    ring.keyframe_insert("rotation_euler", frame=1)
    ring.rotation_euler = (
        math.radians(tilt),
        math.radians(i*30 + 360),
        math.radians(360 * (1 + i*0.5))
    )
    ring.keyframe_insert("rotation_euler", frame=120)

# ── Tagline text ──────────────────────────────────────────────────────────────
bpy.ops.object.text_add(location=(-3.2, 0, -1.5))
tag = bpy.context.object
tag.data.body = "Creative Suite"
tag.data.size = 0.55
tag.data.extrude = 0.05
tag_mat = bpy.data.materials.new("TagMat")
tag_mat.use_nodes = True
tn = tag_mat.node_tree.nodes; tn.clear()
te = tn.new("ShaderNodeEmission")
te.inputs["Color"].default_value = (0.8, 0.9, 1.0, 1.0)
te.inputs["Strength"].default_value = 1.5
to = tn.new("ShaderNodeOutputMaterial")
tag_mat.node_tree.links.new(te.outputs["Emission"], to.inputs["Surface"])
tag.data.materials.append(tag_mat)
bpy.ops.object.convert(target='MESH')

# Fade in tagline
tag.scale = (0, 0, 0)
tag.keyframe_insert("scale", frame=35)
tag.scale = (1, 1, 1)
tag.keyframe_insert("scale", frame=55)

# ── World ─────────────────────────────────────────────────────────────────────
world = bpy.context.scene.world
world.use_nodes = True
bg = world.node_tree.nodes.get("Background")
if bg:
    bg.inputs["Color"].default_value = (0.0, 0.0, 0.02, 1.0)

# ── Render settings ───────────────────────────────────────────────────────────
scene = bpy.context.scene
scene.frame_start = 1
scene.frame_end = 120
scene.render.fps = 24
scene.render.resolution_x = 1280
scene.render.resolution_y = 720
scene.render.image_settings.file_format = "FFMPEG"
scene.render.ffmpeg.format = "MPEG4"
scene.render.ffmpeg.codec = "H264"
scene.render.ffmpeg.constant_rate_factor = "HIGH"
scene.render.filepath = "/ephemeral/agh-promo/agh_logo_reveal.mp4"
scene.render.engine = "BLENDER_EEVEE"

eevee = scene.eevee
if hasattr(eevee, "use_bloom"):
    eevee.use_bloom = True
    eevee.bloom_intensity = 1.2
    eevee.bloom_radius = 8.0
    eevee.bloom_threshold = 0.5

bpy.ops.render.render(animation=True)
print("AGH LOGO RENDER COMPLETE")
```

Click **Run Script** (▶ button). Renders in ~3 minutes.

Output: `agh_logo_reveal.mp4` — 5-second AGH text reveal with glowing rings, scales from zero, tagline fades in.

---

## Step 4 — Generate Background Music (MusicGen)

Open terminal inside XFCE desktop:

```bash
source /opt/audio-env/bin/activate
python3 - << 'EOF'
from audiocraft.models import MusicGen
import torchaudio, os

m = MusicGen.get_pretrained('melody')
m.set_generation_params(duration=95)

audio = m.generate([
    "Epic cinematic orchestral music for a tech product reveal. "
    "Starts minimal and mysterious, builds with intensity, "
    "climaxes at 30 seconds with full orchestra and electronic elements, "
    "inspiring and futuristic, suitable for a premium tech advertisement"
])[0].cpu()

out = "/ephemeral/agh-promo/agh_promo_music.wav"
torchaudio.save(out, audio, 32000)
print(f"Saved: {out}")
EOF
```

Takes ~3 minutes. Result: 95-second custom track, no licensing fees, not available anywhere else.

---

## Step 5 — Edit Final Promo (Kdenlive)

Open **Kdenlive** from XFCE desktop.

### Project setup
- **File → New Project**
- Resolution: `1920×1080`
- Framerate: `24fps`
- Project name: `AGH_Creative_Suite_Promo`

### Import all assets
**Project → Add Clip** → select (`<DATA_DIR>` = `/ephemeral` on Shadeform):
```
<DATA_DIR>/agh-promo/images/agh_workstation_*.png   (futuristic workstation)
<DATA_DIR>/agh-promo/images/agh_creator_*.png       (creative professional)
<DATA_DIR>/agh-promo/images/agh_abstract_ai_*.png    (abstract AI)
<DATA_DIR>/agh-promo/images/agh_gpu_power_*.png      (H100 GPU)
<DATA_DIR>/agh-promo/images/agh_brand_*.png          (AGH brand mark)
<DATA_DIR>/agh-promo/images/agh_no_limits_*.png      (studio / NO LIMITS)
<DATA_DIR>/agh-promo/videos/wan21_workspace.mp4      (futuristic studio)
<DATA_DIR>/agh-promo/videos/wan21_ai_gen.mp4         (AI-generation reveal)
<DATA_DIR>/agh-promo/agh_logo_reveal.mp4
<DATA_DIR>/agh-promo/agh_promo_music.wav
<DATA_DIR>/agh-promo/brand/agh-icon.png              (real logo — overlay track)
```

### Timeline assembly

Drag to Video Track 1 in this order:

| Clip | In | Duration | Effect |
|---|---|---|---|
| Branded intro (banner + logo) | 0s | 5s | Real `og-image.png` bg + `agh-icon.png`, fade in/out |
| `agh_workstation_*.png` | 5s | 4s | Ken Burns zoom |
| `agh_creator_*.png` | 9s | 4s | Ken Burns zoom |
| `agh_logo_reveal.mp4` | 13s | 5s | Fade in |
| `wan21_ai_gen.mp4` | 18s | 10s | Full |
| `agh_abstract_ai_*.png` | 28s | 3s | Quick cut |
| `agh_gpu_power_*.png` | 31s | 3s | Quick cut |
| `wan21_workspace.mp4` | 34s | 15s | Full, cinematic |
| `agh_brand_*.png` | 49s | 4s | Slow zoom |
| `agh_no_limits_*.png` | 53s | 4s | Slow zoom |
| End card (logo + tagline) | 57s | 6s | Real `agh-icon.png` + `aghcloud.ai` |

**Audio Track 1:** `agh_promo_music.wav` — starts at 0s, fades out near the end  
**Overlay track (full timeline):** `brand/agh-icon.png` scaled small, top-right — the persistent watermark

### Add text overlays

The branded intro (0–5s) and end card already carry the real logo + tagline.
Add these lower-thirds / overlays on top:

1. Solution (13–18s, over logo reveal): `"Introducing AGH Creative Suite"`  
   Font: DejaVu Sans Bold, 48, `#00ccff`, centered

2. Features — lower-thirds:  
   - 18s: `"AI Image Generation — Unlimited"`  
   - 34s: `"AI Video — No Time Limits"`  
   Font: 36, white, bottom third

3. End card (57–63s):
   ```
   AGH Creative Suite
   aghcloud.ai
   Your GPU. No Limits.
   ```

### Apply transitions
- Between all clips: **Dissolve** transition, 12 frames (0.5s)
- After logo reveal → `wan21_ai_gen.mp4`: **Wipe** (left to right), 18 frames

### Color grade
Select `wan21_workspace.mp4` → **Effects → Color → Levels**:
- Reduce highlights slightly
- Push midtones warm (+10)
- Add slight vignette for cinema feel

Apply same grade to all video clips: right-click → **Copy Effect** → select all clips → **Paste Effect**

### Render
**File → Render**
- Profile: `H.264/AAC (MP4)`
- Resolution: `1920×1080`
- Quality: `High (CRF 18)`
- Output: `<DATA_DIR>/agh-promo/AGH_Creative_Suite_Promo.mp4`

Click **Render to File** → ~5 minutes.

---

## Final Output

```
<DATA_DIR>/agh-promo/AGH_Creative_Suite_Promo.mp4
```
`<DATA_DIR>` = `/ephemeral` (Shadeform) or `/opt` (single-disk VMs). Script prints exact path.

A ~70-second branded promotional video for AGH Creative Suite, made entirely using AGH Creative Suite.

**Download whole folder to laptop:**
```bash
scp -r shadeform@<SERVER_IP>:<DATA_DIR>/agh-promo/ ~/Desktop/agh-promo/
```

---

## Real brand assets (fetched live from aghcloud.ai)

Step 0 of `demo_creative_suite.sh` pulls the genuine AGH assets straight from the
production site, validates they are real PNGs, and falls back to generated text
cards if the site is unreachable:

- `https://aghcloud.ai/agh-icon.png` — the AGH logo, 548×440 **RGBA (transparent)** —
  used as the intro logo, the end-card mark, and the persistent watermark.
- `https://aghcloud.ai/og-image.png` — the social banner, 1408×768 — used as the
  intro background.

```bash
curl -sL https://aghcloud.ai/agh-icon.png -o brand/agh-icon.png
curl -sL https://aghcloud.ai/og-image.png -o brand/og-image.png
```

## AGH Branding (required for a proper promo look)

The video must look branded, not like raw clips stitched together:

- **Branded intro** — real `og-image.png` banner background + real `agh-icon.png`
  logo overlay + "Creative Suite" + tagline, fade in/out (5s open)
- **Section cards** — labelled transitions ("AI Video Generation — No Time Limits") between each capability
- **Persistent watermark** — real `agh-icon.png` logo scaled small, top-right corner across the ENTIRE video
- **End card** — real `agh-icon.png` logo + "This entire video was made using AGH Creative Suite" + `aghcloud.ai` (6s close)

The automated `demo_creative_suite.sh` composites the **real fetched logo + banner**
for the intro, end card, and watermark (overlaying the PNG, not just `drawtext`
text). If the fetch fails it auto-falls back to `drawtext` text cards so the run
never breaks. For manual Kdenlive edits, add the `agh-icon.png` overlay track
spanning the full timeline.

---

## Automated Version (one command)

The manual steps above are automated end-to-end in `demo_creative_suite.sh`:

```bash
wget -qO demo_creative_suite.sh https://raw.githubusercontent.com/niksresearch/agh-installations/main/demo_creative_suite.sh && sudo bash demo_creative_suite.sh
tail -f <DATA_DIR>/agh-promo/demo.log   # clean progress
```

**Reliable concat:** clips come from different sources (cards, Blender, Wan2.1) with different codec/fps/SAR. Naive `ffmpeg -f concat` fails silently. The script normalizes every segment to 1280x720 @ 24fps yuv420p MPEG-TS first, then concats TS (forgiving), then adds watermark + music in a final pass. This is why the final video reliably appears.

---

## What This Demonstrates

Every tool in the suite contributed to this video:

| Contribution | Tool |
|---|---|
| Real logo + banner | **curl** — fetched live from `aghcloud.ai` |
| Brand images | **ComfyUI** (port 8188, FLUX/SD) |
| Cinematic video clips | **Wan2.1** |
| AGH logo 3D reveal | **Blender** (headless EEVEE) |
| Background music | **MusicGen** |
| Branding + assembly | **FFmpeg** (auto) / **Kdenlive** (manual) |

**The story:** We used AGH Creative Suite to promote AGH Creative Suite.  
No agency. No Adobe. No subscriptions. One GPU. One hour.

---

## The Tagline This Proves

> *"This video was made entirely using AGH Creative Suite. You're watching the product."*

Put that at the end of the video.
