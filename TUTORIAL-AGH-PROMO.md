# AGH Creative Suite — How We Made Our Own Promo Video

**The story:** This promotional video for AGH Creative Suite was created entirely *using* AGH Creative Suite.

No external tools. No agency. No subscriptions.  
One H100. One hour. ~$2.50.

---

## What We're Building

A 90-second promo video structured as:

| Segment | Duration | Tool | Description |
|---|---|---|---|
| 1. Hook | 4s | FFmpeg | Dark opening — "Your GPU. Your Canvas." |
| 2. Problem | 8s | Wan2.1 + FFmpeg | Show the frustration of limited tools |
| 3. Solution reveal | 5s | Blender | AGH logo 3D reveal animation |
| 4. Image gen demo | 15s | Fooocus → Kdenlive | 6 images generated live, slideshow |
| 5. Video gen demo | 20s | Wan2.1 | AI video of futuristic creative workspace |
| 6. 3D demo | 12s | Blender | Orbiting planet / abstract tech render |
| 7. Call to action | 6s | FFmpeg | Portal URL, tagline |
| Music (full) | 90s | MusicGen | Epic cinematic underscore |

---

## Step 1 — Generate Brand Images (Fooocus)

Open portal → click **Fooocus** → `http://localhost:7865`

Generate these 6 images. Each takes ~60 seconds. No limits.

### Image 1 — Hero: "The AGH Workstation"
```
A sleek futuristic AI creative workstation glowing with blue and purple light, 
multiple holographic screens showing AI-generated artwork, dark minimal setup, 
cinematic lighting, ultra detailed, 8K, concept art style
```
Settings: Realistic, 16:9

### Image 2 — "Before AGH" (frustrated creator)
```
A frustrated graphic designer staring at a laptop screen showing a paywall and 
"credits exhausted" message, dark moody lighting, editorial photography style, 
cinematic color grade
```
Settings: Realistic, 16:9

### Image 3 — "After AGH" (empowered creator)  
```
A confident creative professional in front of multiple screens showing stunning 
AI-generated videos and images, golden hour light, inspired expression, 
cinematic, aspirational lifestyle photography
```
Settings: Realistic, 16:9

### Image 4 — Abstract AI creativity
```
Abstract visualization of artificial intelligence creativity — flowing neural 
networks forming into beautiful art pieces, electric blue and purple particles, 
deep space background, photorealistic digital art, 8K
```
Settings: MidJourney style, 16:9

### Image 5 — GPU power
```
An H100 GPU chip glowing with neon blue light, futuristic close-up macro shot, 
cinematic dramatic lighting, chrome and silicon textures, tech product photography
```
Settings: Realistic, 16:9

### Image 6 — AGH brand closer
```
The text "AGH" formed from glowing particles and light trails against a dark 
background, futuristic logo reveal style, electric blue and cyan colors, 
cinematic, 8K render quality
```
Settings: Anime / Digital Art, 16:9

**Save all 6** to `/ephemeral/promo/images/`

---

## Step 2 — Generate Promo Videos (Wan2.1)

Open portal → click **Wan2.1 Video** → `http://localhost:7870`

### Video A — The Creative Workspace (main hero clip, 20s)
```
A futuristic AI creative studio. Holographic screens display stunning AI-generated 
artwork being created in real-time. Glowing particle effects flow between screens. 
Camera slowly pushes forward through the workspace. Deep blue and purple lighting. 
Cinematic, photorealistic, ultra smooth motion, 4K commercial quality.
```
- Steps: 50 | Guidance: 7.0 | Resolution: 1280×720

### Video B — AI Generation in Action (process clip, 15s)
```
An abstract visualization of an AI generating an image — pixels assembling from 
noise into a stunning photorealistic landscape. Time-lapse style, particle effects, 
glowing neural pathways, electric blue light, dramatic reveal, cinematic 4K.
```
- Steps: 50 | Guidance: 6.5 | Resolution: 1280×720

### Video C — GPU Power (product capability clip, 10s)
```
An extreme close-up of a GPU chip running at full power, glowing blue and orange 
heat effects, electricity arcing between components, slow motion, macro cinematic 
shot, dramatic industrial beauty, 4K.
```
- Steps: 40 | Guidance: 6.0 | Resolution: 1280×720

Each generation: ~8-15 min on H100. Queue all three before going for coffee.

**Save to:** `/ephemeral/promo/videos/`

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
scene.render.filepath = "/ephemeral/promo/agh_logo_reveal.mp4"
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

out = "/ephemeral/promo/agh_promo_music.wav"
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
**Project → Add Clip** → select:
```
/ephemeral/promo/images/img_01.png  (AGH workstation)
/ephemeral/promo/images/img_02.png  (frustrated creator)
/ephemeral/promo/images/img_03.png  (empowered creator)
/ephemeral/promo/images/img_04.png  (abstract AI)
/ephemeral/promo/images/img_05.png  (GPU)
/ephemeral/promo/images/img_06.png  (AGH brand)
/ephemeral/promo/videos/video_A.mp4 (creative workspace)
/ephemeral/promo/videos/video_B.mp4 (AI generation)
/ephemeral/promo/videos/video_C.mp4 (GPU power)
/ephemeral/promo/agh_logo_reveal.mp4
/ephemeral/promo/agh_promo_music.wav
```

### Timeline assembly

Drag to Video Track 1 in this order:

| Clip | In | Duration | Effect |
|---|---|---|---|
| Black (title card) | 0s | 4s | Add text: "Your GPU. Your Canvas." |
| `img_02.png` (frustrated) | 4s | 4s | Ken Burns zoom |
| `img_03.png` (empowered) | 8s | 4s | Ken Burns zoom, faster |
| `agh_logo_reveal.mp4` | 12s | 5s | Fade in |
| `video_B.mp4` (AI gen) | 17s | 10s | Full |
| `img_04.png` (abstract AI) | 27s | 3s | Quick cut |
| `img_01.png` (workstation) | 30s | 3s | Quick cut |
| `img_05.png` (GPU) | 33s | 3s | Quick cut |
| `video_A.mp4` (workspace) | 36s | 15s | Full, cinematic |
| `video_C.mp4` (GPU) | 51s | 8s | Trimmed to 8s |
| `img_06.png` (AGH brand) | 59s | 5s | Slow zoom |
| Black (end card) | 64s | 6s | Text: URL + tagline |

**Audio Track 1:** `agh_promo_music.wav` — starts at 0s, fades out at 68s

### Add text overlays

Double-click each text card in timeline → **Edit** text:

1. Opening (0–4s): `"Your GPU. Your Canvas."`  
   Font: DejaVu Sans Bold, Size 72, white, centered

2. Problem (4–8s): `"Commercial tools limit you"`  
   Font: 36, `#ff4444`, bottom third

3. Solution (12–17s): `"Introducing AGH Creative Suite"`  
   Font: 48, `#00ccff`, centered

4. Features (17–36s): Add lower-thirds:  
   - 17s: `"AI Image Generation — Unlimited"`  
   - 27s: `"AI Video — No Time Limits"`

5. End card (64–70s):
   ```
   AGH Creative Suite
   aghcloud.ai
   Your GPU. No Limits.
   ```

### Apply transitions
- Between all clips: **Dissolve** transition, 12 frames (0.5s)
- After logo reveal → video B: **Wipe** (left to right), 18 frames

### Color grade
Select `video_A.mp4` → **Effects → Color → Levels**:
- Reduce highlights slightly
- Push midtones warm (+10)
- Add slight vignette for cinema feel

Apply same grade to all video clips: right-click → **Copy Effect** → select all clips → **Paste Effect**

### Render
**File → Render**
- Profile: `H.264/AAC (MP4)`
- Resolution: `1920×1080`
- Quality: `High (CRF 18)`
- Output: `/ephemeral/promo/AGH_Creative_Suite_FINAL.mp4`

Click **Render to File** → ~5 minutes.

---

## Final Output

```
/ephemeral/promo/AGH_Creative_Suite_FINAL.mp4
```

A 70-second promotional video for AGH Creative Suite, made entirely using AGH Creative Suite.

**Download to laptop:**
```bash
scp shadeform@<SERVER_IP>:/ephemeral/promo/AGH_Creative_Suite_FINAL.mp4 ~/Desktop/
```

---

## What This Demonstrates

Every tool in the suite contributed to this video:

| Contribution | Tool |
|---|---|
| All 6 brand images | **Fooocus** |
| 3 cinematic video clips | **Wan2.1** |
| AGH logo 3D reveal | **Blender** |
| Background music | **MusicGen** |
| Final edit + text + grade | **Kdenlive** |

**The story:** We used AGH Creative Suite to promote AGH Creative Suite.  
No agency. No Adobe. No subscriptions. One GPU. One hour.

---

## The Tagline This Proves

> *"This video was made entirely using AGH Creative Suite. You're watching the product."*

Put that at the end of the video.
