# AGH Creative Suite — Marketing Executive Walkthrough

**Persona:** Sarah, Marketing Lead at *Lumina Tech* — launching a new smart desk lamp called **Lumina Pro**.

She needs:
- Hero images for the product page
- Social media graphics (LinkedIn, Instagram)
- A 30-second product launch video
- A 3D render of the lamp for the press kit

Total time: ~45 minutes. Cost: ~$2 GPU rental. No design software on her laptop.

---

## Step 1 — Access the Studio

After setup completes, Sarah gets a URL in her terminal:

```
Portal: https://xxxx.trycloudflare.com
```

She opens it in Chrome. Sees the AGH portal — dark themed, lists every tool. No install, no SSH.

**Or from inside the desktop:**
- Open the VNC desktop URL → `https://yyyy.trycloudflare.com/vnc.html`
- Enter password
- Chrome opens automatically, already on the portal page
- Every tool is one click away

---

## Step 2 — Generate Product Hero Images (Fooocus)

Click **Fooocus** in the portal → opens at `http://localhost:7865`

Fooocus feels exactly like Midjourney — just a prompt box and a Generate button.

### Image 1: Product hero shot

**Prompt:**
```
A sleek minimalist smart desk lamp on a white marble desk, modern home office background, 
soft warm lighting, product photography style, shallow depth of field, 4K, ultra detailed, 
professional commercial photography
```

- Style: **Realistic** (default)
- Aspect Ratio: **16:9** (website hero)
- Click **Generate**

Result: photorealistic product-style image in ~60 seconds. No credits. No watermarks.

### Image 2: Lifestyle shot

**Prompt:**
```
Young professional working late at a minimalist desk, warm glowing smart lamp illuminating 
the workspace, city view through window at night, cinematic mood, editorial photography style
```

### Image 3: Instagram square

Change aspect ratio to **1:1**

**Prompt:**
```
Close-up of a modern smart lamp with soft bokeh background, gradient from warm amber to cool 
white light, product detail shot, luxury feel, Instagram-ready
```

**Download:** Right-click → Save image. Done.

> **vs Midjourney:** Same quality. No subscription. No 25-image daily limit. Generate 500 images if needed — same GPU hour cost.

---

## Step 3 — Generate Product Launch Video (Wan2.1)

Click **Wan2.1 Video** in the portal → opens at `http://localhost:7870`

Simple form: prompt, steps, guidance scale, resolution.

### Video 1: Hero reveal (30 seconds)

**Prompt:**
```
A sleek modern smart desk lamp slowly illuminates on a minimalist white desk. 
Warm golden light gradually fills the room. Camera slowly orbits around the product. 
Cinematic, photorealistic, smooth motion, commercial advertisement style, 4K quality
```

- Steps: **50**
- Guidance: **6.0**
- Resolution: **1280×720**
- Click **Generate Video**

Generation takes ~8-15 minutes on H100. Sarah grabs coffee.

Result: a smooth, cinematic product reveal video. No "8 second limit" like RunwayML.

### Video 2: Lifestyle scene

**Prompt:**
```
Time-lapse of a home office going from bright daylight to evening. Smart lamp automatically 
adjusts its color temperature. Person working, looking productive and happy. 
Cinematic, warm color grade, commercial feel
```

> **vs RunwayML:** RunwayML charges $0.05/second = $1.50 for a 30-second clip. On H100, generate as many as needed for ~$2.50/hour total.

---

## Step 4 — 3D Product Render (Blender)

For the press kit, Sarah needs a clean 3D render showing all angles — something a photographer can't easily do without a physical prototype.

Open the XFCE desktop → find **Blender** in the applications menu (or terminal: `blender`).

### Quick 3D lamp render

1. **File → New → General** — start fresh scene
2. Delete default cube: `X` → Delete
3. **Add → Mesh → Cylinder** — lamp base
   - Scale: `S, Z, 0.1` then Enter (flatten into base)
4. **Add → Mesh → Cylinder** — lamp pole
   - Scale: `S, X, 0.05`, `S, Y, 0.05`, `S, Z, 2`
   - Move up: `G, Z, 1`
5. **Add → Mesh → UV Sphere** — lamp head
   - Scale: `S, 0.4`
   - Move: `G, Z, 2.2`

**Add emission material to lamp head:**
- Select sphere → Material Properties → New
- Surface: **Emission**
- Color: warm white (`#FFF5E0`)
- Strength: `8.0`

**Camera setup:**
- Select camera → `G` to move → position at 45° angle
- `Numpad 0` → camera view

**Render:**
- Render Properties → Engine: **EEVEE**
- Resolution: 2560×1440
- Enable **Bloom** (for glow effect)
- `F12` → render

Result: clean 3D render suitable for press kit, website, presentations.

### Turntable animation (optional, ~5 min)

```python
# Paste into Blender's Python console (Scripting tab):
import bpy, math

# Select lamp head
obj = bpy.data.objects["Sphere"]

# Keyframe rotation: 0° at frame 1, 360° at frame 120
obj.rotation_euler = (0, 0, 0)
obj.keyframe_insert("rotation_euler", frame=1)
obj.rotation_euler = (0, 0, math.radians(360))
obj.keyframe_insert("rotation_euler", frame=120)

# Render animation
bpy.context.scene.render.filepath = "/ephemeral/lamp_turntable.mp4"
bpy.context.scene.render.image_settings.file_format = "FFMPEG"
bpy.ops.render.render(animation=True)
```

Output: smooth 5-second 360° product spin. Perfect for social media.

---

## Step 5 — Assemble Everything (Kdenlive)

Open **Kdenlive** from the XFCE desktop applications menu.

1. **File → New Project** → set resolution 1920×1080, 24fps
2. **Project → Add Clip** → add all generated assets:
   - `wan21_hero_reveal.mp4`
   - `lamp_turntable.mp4` (Blender)
   - `img_01.png`, `img_02.png`, `img_03.png` (Fooocus images)
3. Drag clips to timeline in sequence
4. Add text overlay: **Effects → Text** → "Lumina Pro — Now Available"
5. Add background music (if MusicGen installed): drag `music.wav` to audio track
6. **File → Render** → MP4, H264, high quality

Final video: 30-45 second product launch reel ready for YouTube, LinkedIn, Instagram.

---

## What Sarah produced in 45 minutes

| Asset | Tool | Time | Commercial equivalent |
|---|---|---|---|
| 3 product hero images | Fooocus | 3 min | $200-500 (photographer) |
| 2 product videos (30s each) | Wan2.1 | 20 min | $300-600 (RunwayML + editing) |
| 3D press kit render | Blender | 10 min | $500-1000 (3D artist) |
| Turntable animation | Blender | 5 min | $200-400 |
| Background music | MusicGen | 2 min | $50-200 (licensing) |
| Final edited reel | Kdenlive | 5 min | $200-500 (video editor) |

**Total GPU cost: ~$2.50** (1 hour on H100)

**Estimated agency cost: $1,500–3,200**

---

## Quick Reference — Best Prompts for Product Marketing

### Fooocus — Product images

```
[product name] on [surface], [background], [lighting style], product photography, 
commercial, ultra detailed, 4K, no watermark
```

Lighting styles that work well:
- `soft studio lighting` — clean product shot
- `dramatic side lighting` — premium feel
- `golden hour natural light` — lifestyle/editorial
- `neon accent lighting` — tech/modern

### Wan2.1 — Product videos

```
[product] in [environment]. [camera movement]. [mood]. Cinematic, smooth motion, 
commercial advertisement, photorealistic, 4K quality.
```

Camera movements: `slow orbit`, `pull back reveal`, `push in close-up`, `top-down overhead`

Moods: `warm and inviting`, `clean and minimal`, `dramatic and premium`, `energetic and modern`

### Blender — Quick shortcuts

| Action | Shortcut |
|---|---|
| Add object | `Shift+A` |
| Move | `G` (then X/Y/Z to lock axis) |
| Scale | `S` (then X/Y/Z) |
| Rotate | `R` (then X/Y/Z) |
| Camera view | `Numpad 0` |
| Render | `F12` |
| Material properties | Right panel → sphere icon |

---

## Troubleshooting

**Fooocus loads but generate button does nothing:**
```bash
# Check log
cat /ephemeral/fooocus.log | tail -20
# Restart
pkill -f "launch.py" && source /opt/fooocus-env/bin/activate && cd /opt/Fooocus && python launch.py --listen --port 7865 &
```

**Wan2.1 video generation fails:**
```bash
# Check TMPDIR has space
df -h /ephemeral
# Run manually with explicit paths
source /opt/wan21-env/bin/activate && cd /opt/Wan2.1
TMPDIR=/ephemeral/tmp python generate.py --task t2v-14B --size 1280*720 \
  --ckpt_dir /ephemeral/models/wan21 --sample_steps 50 \
  --prompt "your prompt" --save_file /ephemeral/output.mp4
```

**Blender won't open in desktop:**
```bash
# Run from terminal inside desktop
blender
# Or headless render
blender --background --python /path/to/script.py
```

**Download outputs to laptop:**
```bash
# From your laptop
scp shadeform@<SERVER_IP>:/ephemeral/agh-demo/AGH_Creative_Suite_Demo.mp4 ~/Desktop/
scp -r shadeform@<SERVER_IP>:/ephemeral/frames/ ~/Desktop/lumina-images/
```
