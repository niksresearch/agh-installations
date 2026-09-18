#!/usr/bin/env bash
# AGH Creative Suite — model performance benchmark
#
# Measures, per model, what you can publish on a spec/sales sheet:
#   model name · input (prompt/res/steps/frames) · output (res/duration/size) ·
#   wall time · peak VRAM · throughput · derived cost (GPU-hour rate x time).
#
# For chat/LLM models it also records prompt/completion TOKENS and tokens/sec
# (image/video/audio have no "tokens" — their units are steps, frames, seconds).
#
# Usage:
#   sudo bash benchmark.sh                      # all installed creative models
#   sudo bash benchmark.sh image video          # only these groups
#   sudo bash benchmark.sh image video audio upscale chat
#   sudo GPU_RATE=2.50 bash benchmark.sh        # fill the cost column ($/GPU-hour)
#   sudo CHAT_URL=http://127.0.0.1:8000/v1 CHAT_MODEL=llama3 bash benchmark.sh chat
#
# Groups: image  video  audio  upscale  chat
# Config env:
#   GPU_RATE   $/GPU-hour used for the cost column (default 0 = blank)
#   CHAT_URL   OpenAI-compatible base URL for the chat benchmark (e.g. AGH LLM suite)
#   CHAT_MODEL model name to request at CHAT_URL
#   CHAT_KEY   bearer token for CHAT_URL (optional)
#
# Outputs:  /tmp/agh-bench/results.csv  (machine)  +  results.md  (sales-ready table)
set -uo pipefail

OUT=/tmp/agh-bench
CSV="${OUT}/results.csv"
MD="${OUT}/results.md"
mkdir -p "${OUT}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log() { echo -e "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
[[ -f /etc/profile.d/agh-paths.sh ]] && source /etc/profile.d/agh-paths.sh
if [[ -z "${AGH_MODELS:-}" ]]; then
  for c in /ephemeral /data /mnt/data; do mountpoint -q "$c" 2>/dev/null && { AGH_MODELS="$c/models"; break; }; done
  AGH_MODELS="${AGH_MODELS:-/opt/models}"
fi
MODELS_DIR="${AGH_MODELS}"
# Robust pod pick: the sleep-infinity whose mount namespace actually has the tools.
# A stale/duplicate 'sleep infinity' from an earlier pod gives the wrong namespace
# (nsenter then fails with 'cannot open /proc/<pid>/ns/mnt' on every call).
POD_PID=""
for _pid in $(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}'); do
  if nsenter -t "$_pid" -m -- test -d /opt/comfyui-env 2>/dev/null; then POD_PID="$_pid"; break; fi
done
[[ -n "$POD_PID" ]] || POD_PID=$(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | head -1)
[[ -n "$POD_PID" ]] || { echo "Pod not running — run setup_creative_suite.sh first."; exit 1; }
inpod() { nsenter -t "$POD_PID" -m -- bash -c "$1"; }

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "GPU")
GPU_RATE="${GPU_RATE:-0}"

BENCH_GROUPS=("$@"); [[ ${#BENCH_GROUPS[@]} -eq 0 ]] && BENCH_GROUPS=(image video audio upscale chat)
has_group() { local g; for g in "${BENCH_GROUPS[@]}"; do [[ "$g" == "$1" ]] && return 0; done; return 1; }

# CSV header (once)
echo "modality,model,input,output,wall_s,peak_vram_mb,throughput,tokens,cost_usd" > "${CSV}"

# ── VRAM sampler: max memory.used (MB) over the job window ─────────────────────
start_vram() { : > "${OUT}/.vram"; ( while :; do nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 >> "${OUT}/.vram"; sleep 1; done ) & echo $!; }
stop_vram()  { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; sort -n "${OUT}/.vram" 2>/dev/null | tail -1; }

csv_field() { printf '%s' "$1" | sed 's/"/""/g'; }
record() {  # modality model input output wall peak throughput tokens
  local cost=""
  [[ "$GPU_RATE" != "0" ]] && cost=$(awk "BEGIN{printf \"%.4f\", ${5:-0}/3600*${GPU_RATE}}")
  printf '%s,"%s","%s","%s",%s,%s,"%s","%s",%s\n' \
    "$1" "$(csv_field "$2")" "$(csv_field "$3")" "$(csv_field "$4")" "${5:-}" "${6:-}" "$(csv_field "${7:-}")" "${8:-}" "${cost}" >> "${CSV}"
  log "  ${GREEN}✓${NC} ${2}: ${5}s, peak ${6}MB${7:+, ${7}}${8:+, ${8} tok}${cost:+, \$${cost}}"
}

# ffprobe helpers (run in pod)
vid_spec()  { inpod "ffprobe -v error -select_streams v:0 -show_entries stream=width,height,nb_frames,r_frame_rate -show_entries format=duration -of default=nw=1 '$1' 2>/dev/null" | tr '\n' ' '; }
aud_dur()   { inpod "ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 '$1' 2>/dev/null"; }
fsize()     { du -h "$1" 2>/dev/null | cut -f1; }

PROMPT="A futuristic AI creative studio, holographic screens, glowing blue particles, cinematic, photorealistic, smooth motion, 4K"

log "${BOLD}════════════════════════════════════════════════════════════════${NC}"
log "${BOLD}  AGH Creative Suite — model benchmark${NC}"
log "  GPU:        ${GPU_NAME}"
log "  Rate:       ${GPU_RATE} \$/GPU-hour $( [[ "$GPU_RATE" == "0" ]] && echo '(set GPU_RATE to fill cost)')"
log "  Groups:     ${BENCH_GROUPS[*]}"
log "  Output:     ${OUT}/"
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"

# ── IMAGE (ComfyUI: FLUX or SDXL/SD1.5) ───────────────────────────────────────
if has_group image; then
  log "${CYAN}▶ image${NC}"
  if curl -s --connect-timeout 3 http://127.0.0.1:8188/system_stats >/dev/null 2>&1; then
    CKPT=$(ls "${MODELS_DIR}"/comfyui/checkpoints/*.safetensors 2>/dev/null | head -1 | xargs -n1 basename)
    if [[ -n "$CKPT" ]]; then
      SEED=$(( (RANDOM<<15) ^ RANDOM ))
      vp=$(start_vram); t0=$(date +%s)
      PID=$(curl -s -X POST http://127.0.0.1:8188/prompt -H "Content-Type: application/json" \
        -d "{\"prompt\":{\"1\":{\"class_type\":\"CheckpointLoaderSimple\",\"inputs\":{\"ckpt_name\":\"${CKPT}\"}},\"2\":{\"class_type\":\"CLIPTextEncode\",\"inputs\":{\"text\":\"${PROMPT}\",\"clip\":[\"1\",1]}},\"3\":{\"class_type\":\"CLIPTextEncode\",\"inputs\":{\"text\":\"blurry\",\"clip\":[\"1\",1]}},\"4\":{\"class_type\":\"EmptyLatentImage\",\"inputs\":{\"width\":1024,\"height\":1024,\"batch_size\":1}},\"5\":{\"class_type\":\"KSampler\",\"inputs\":{\"model\":[\"1\",0],\"positive\":[\"2\",0],\"negative\":[\"3\",0],\"latent_image\":[\"4\",0],\"seed\":${SEED},\"steps\":25,\"cfg\":7,\"sampler_name\":\"euler\",\"scheduler\":\"normal\",\"denoise\":1}},\"6\":{\"class_type\":\"VAEDecode\",\"inputs\":{\"samples\":[\"5\",0],\"vae\":[\"1\",2]}},\"7\":{\"class_type\":\"SaveImage\",\"inputs\":{\"images\":[\"6\",0],\"filename_prefix\":\"bench\"}}}}" \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('prompt_id',''))" 2>/dev/null)
      for _ in $(seq 1 60); do sleep 2; [[ "$(curl -s http://127.0.0.1:8188/history/$PID | python3 -c 'import sys,json;print("y" if json.load(sys.stdin) else "")' 2>/dev/null)" == "y" ]] && break; done
      f=$(curl -s http://127.0.0.1:8188/history/$PID | python3 -c "import sys,json;d=json.load(sys.stdin);print(list(d.values())[0]['outputs']['7']['images'][0]['filename'])" 2>/dev/null)
      curl -s "http://127.0.0.1:8188/view?filename=$f&type=output" -o "${OUT}/image.png" 2>/dev/null
      t1=$(date +%s); wall=$((t1-t0)); peak=$(stop_vram "$vp")
      record image "ComfyUI/${CKPT%.safetensors}" "1024x1024, 25 steps" "1024x1024 PNG $(fsize "${OUT}/image.png")" "$wall" "$peak" "$(awk "BEGIN{printf \"%.2f s/img\", $wall}")" ""
    else log "  ${YELLOW}○ no checkpoint${NC}"; fi
  else log "  ${YELLOW}○ ComfyUI not running (:8188)${NC}"; fi
fi

# ── VIDEO (Wan2.1 + diffusers LTX/CogVideoX/Hunyuan) ──────────────────────────
if has_group video; then
  log "${CYAN}▶ video${NC}"

  if [[ -d /opt/Wan2.1 ]]; then
    vp=$(start_vram); t0=$(date +%s)
    inpod "source /opt/wan21-env/bin/activate; cd /opt/Wan2.1; python generate.py --task t2v-14B --size 1280*720 --ckpt_dir ${MODELS_DIR}/wan21 --frame_num 81 --sample_steps 30 --sample_guide_scale 6.0 --prompt '${PROMPT}' --save_file ${OUT}/wan.mp4" >/dev/null 2>>"${OUT}/wan.err"
    t1=$(date +%s); wall=$((t1-t0)); peak=$(stop_vram "$vp")
    [[ -s "${OUT}/wan.mp4" ]] && record video "Wan2.1-14B" "720p, 81 frames, 30 steps" "$(vid_spec "${OUT}/wan.mp4")$(fsize "${OUT}/wan.mp4")" "$wall" "$peak" "$(awk "BEGIN{printf \"%.2f s/frame\", $wall/81}")" "" || log "  ${RED}✗ Wan2.1 (see wan.err)${NC}"
  else log "  ${YELLOW}○ Wan2.1 not installed${NC}"; fi

  if [[ -d /opt/agh-video-env ]]; then
    # LTX-Video
    vp=$(start_vram); t0=$(date +%s)
    inpod "source /opt/agh-video-env/bin/activate; export HF_HOME=${MODELS_DIR}/hf-cache; python - <<'PY' 2>>${OUT}/ltx.err
import torch
from diffusers import LTXPipeline
from diffusers.utils import export_to_video
p=LTXPipeline.from_pretrained('Lightricks/LTX-Video', torch_dtype=torch.bfloat16); p.enable_model_cpu_offload()
v=p(prompt='${PROMPT}', width=768, height=512, num_frames=97, num_inference_steps=30).frames[0]
export_to_video(v, '${OUT}/ltx.mp4', fps=24)
PY" >/dev/null 2>&1
    t1=$(date +%s); wall=$((t1-t0)); peak=$(stop_vram "$vp")
    [[ -s "${OUT}/ltx.mp4" ]] && record video "LTX-Video" "768x512, 97 frames, 30 steps" "$(vid_spec "${OUT}/ltx.mp4")$(fsize "${OUT}/ltx.mp4")" "$wall" "$peak" "$(awk "BEGIN{printf \"%.2f s/frame\", $wall/97}")" "" || log "  ${YELLOW}○ LTX (not installed or failed)${NC}"

    # CogVideoX-5B
    vp=$(start_vram); t0=$(date +%s)
    inpod "source /opt/agh-video-env/bin/activate; export HF_HOME=${MODELS_DIR}/hf-cache; python - <<'PY' 2>>${OUT}/cog.err
import torch
from diffusers import CogVideoXPipeline
from diffusers.utils import export_to_video
p=CogVideoXPipeline.from_pretrained('THUDM/CogVideoX-5b', torch_dtype=torch.bfloat16); p.enable_model_cpu_offload(); p.vae.enable_tiling()
v=p(prompt='${PROMPT}', num_frames=49, guidance_scale=6.0, num_inference_steps=50).frames[0]
export_to_video(v, '${OUT}/cog.mp4', fps=8)
PY" >/dev/null 2>&1
    t1=$(date +%s); wall=$((t1-t0)); peak=$(stop_vram "$vp")
    [[ -s "${OUT}/cog.mp4" ]] && record video "CogVideoX-5B" "720x480, 49 frames, 50 steps" "$(vid_spec "${OUT}/cog.mp4")$(fsize "${OUT}/cog.mp4")" "$wall" "$peak" "$(awk "BEGIN{printf \"%.2f s/frame\", $wall/49}")" "" || log "  ${YELLOW}○ CogVideoX (not installed or failed)${NC}"

    # HunyuanVideo
    vp=$(start_vram); t0=$(date +%s)
    inpod "source /opt/agh-video-env/bin/activate; export HF_HOME=${MODELS_DIR}/hf-cache; python - <<'PY' 2>>${OUT}/hun.err
import torch
from diffusers import HunyuanVideoPipeline, HunyuanVideoTransformer3DModel
from diffusers.utils import export_to_video
r='hunyuanvideo-community/HunyuanVideo'
tr=HunyuanVideoTransformer3DModel.from_pretrained(r, subfolder='transformer', torch_dtype=torch.bfloat16)
p=HunyuanVideoPipeline.from_pretrained(r, transformer=tr, torch_dtype=torch.float16); p.enable_model_cpu_offload(); p.vae.enable_tiling()
v=p(prompt='${PROMPT}', num_frames=61, height=544, width=960, num_inference_steps=30).frames[0]
export_to_video(v, '${OUT}/hun.mp4', fps=15)
PY" >/dev/null 2>&1
    t1=$(date +%s); wall=$((t1-t0)); peak=$(stop_vram "$vp")
    [[ -s "${OUT}/hun.mp4" ]] && record video "HunyuanVideo" "960x544, 61 frames, 30 steps" "$(vid_spec "${OUT}/hun.mp4")$(fsize "${OUT}/hun.mp4")" "$wall" "$peak" "$(awk "BEGIN{printf \"%.2f s/frame\", $wall/61}")" "" || log "  ${YELLOW}○ Hunyuan (not installed or failed)${NC}"
  else log "  ${YELLOW}○ AGH Video Studio not installed${NC}"; fi
fi

# ── UPSCALE (Real-ESRGAN) ─────────────────────────────────────────────────────
if has_group upscale; then
  log "${CYAN}▶ upscale${NC}"
  if [[ -d /opt/enhancement-env && -s "${OUT}/image.png" ]]; then
    vp=$(start_vram); t0=$(date +%s)
    inpod "source /opt/enhancement-env/bin/activate; python - <<'PY' 2>>${OUT}/esrgan.err
import sys,types,torchvision.transforms.functional as _F
if 'torchvision.transforms.functional_tensor' not in sys.modules:
    m=types.ModuleType('torchvision.transforms.functional_tensor'); m.rgb_to_grayscale=_F.rgb_to_grayscale
    sys.modules['torchvision.transforms.functional_tensor']=m
import cv2
from realesrgan import RealESRGANer
from basicsr.archs.rrdbnet_arch import RRDBNet
mdl=RRDBNet(num_in_ch=3,num_out_ch=3,num_feat=64,num_block=23,num_grow_ch=32,scale=4)
up=RealESRGANer(scale=4, model_path='${MODELS_DIR}/realesrgan/RealESRGAN_x4plus.pth', model=mdl, half=True)
img=cv2.imread('${OUT}/image.png'); out,_=up.enhance(img, outscale=4); cv2.imwrite('${OUT}/image_4x.png', out)
PY" >/dev/null 2>&1
    t1=$(date +%s); wall=$((t1-t0)); peak=$(stop_vram "$vp")
    [[ -s "${OUT}/image_4x.png" ]] && record upscale "Real-ESRGAN x4plus" "1024x1024 in, 4x" "4096x4096 PNG $(fsize "${OUT}/image_4x.png")" "$wall" "$peak" "" "" || log "  ${YELLOW}○ ESRGAN failed${NC}"
  else log "  ${YELLOW}○ ESRGAN not installed or no source image (run 'image' group first)${NC}"; fi
fi

# ── AUDIO (MusicGen + Bark) ───────────────────────────────────────────────────
if has_group audio; then
  log "${CYAN}▶ audio${NC}"
  if [[ -d /opt/audio-env ]]; then
    vp=$(start_vram); t0=$(date +%s)
    inpod "source /opt/audio-env/bin/activate; python - <<'PY' 2>>${OUT}/music.err
from audiocraft.models import MusicGen
import torchaudio
m=MusicGen.get_pretrained('melody'); m.set_generation_params(duration=30)
a=m.generate(['epic cinematic orchestral tech reveal'])[0].cpu()
torchaudio.save('${OUT}/music.wav', a, 32000)
PY" >/dev/null 2>&1
    t1=$(date +%s); wall=$((t1-t0)); peak=$(stop_vram "$vp")
    [[ -s "${OUT}/music.wav" ]] && record audio "MusicGen-melody" "30s target" "$(aud_dur "${OUT}/music.wav")s WAV $(fsize "${OUT}/music.wav")" "$wall" "$peak" "$(awk "BEGIN{printf \"%.2fx realtime\", 30/($wall==0?1:$wall)}")" "" || log "  ${RED}✗ MusicGen${NC}"
  else log "  ${YELLOW}○ MusicGen not installed${NC}"; fi

  if [[ -d /opt/voice-env ]]; then
    vp=$(start_vram); t0=$(date +%s)
    inpod "source /opt/voice-env/bin/activate; python - <<'PY' 2>>${OUT}/bark.err
from bark import SAMPLE_RATE, generate_audio, preload_models
from scipy.io.wavfile import write
import numpy as np
preload_models()
a=generate_audio('Welcome to A G H Creative Suite. Your G P U. Your canvas. No limits.')
write('${OUT}/voice.wav', SAMPLE_RATE, (a*32767).astype(np.int16))
PY" >/dev/null 2>&1
    t1=$(date +%s); wall=$((t1-t0)); peak=$(stop_vram "$vp")
    [[ -s "${OUT}/voice.wav" ]] && record audio "Bark TTS" "1 sentence (~12 words)" "$(aud_dur "${OUT}/voice.wav")s WAV $(fsize "${OUT}/voice.wav")" "$wall" "$peak" "" "" || log "  ${RED}✗ Bark${NC}"
  else log "  ${YELLOW}○ Bark not installed${NC}"; fi
fi

# ── CHAT (optional, OpenAI-compatible endpoint — e.g. AGH LLM suite) ───────────
if has_group chat; then
  log "${CYAN}▶ chat${NC}"
  if [[ -n "${CHAT_URL:-}" && -n "${CHAT_MODEL:-}" ]]; then
    AUTH=(); [[ -n "${CHAT_KEY:-}" ]] && AUTH=(-H "Authorization: Bearer ${CHAT_KEY}")
    vp=$(start_vram); t0=$(date +%s)
    RESP=$(curl -s "${CHAT_URL%/}/chat/completions" -H "Content-Type: application/json" "${AUTH[@]}" \
      -d "{\"model\":\"${CHAT_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a 150-word product description for an AI creative cloud.\"}],\"max_tokens\":256}" 2>>"${OUT}/chat.err")
    t1=$(date +%s); wall=$((t1-t0)); peak=$(stop_vram "$vp")
    PT=$(printf '%s' "$RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('usage',{}).get('prompt_tokens',''))" 2>/dev/null)
    CT=$(printf '%s' "$RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('usage',{}).get('completion_tokens',''))" 2>/dev/null)
    if [[ -n "$CT" ]]; then
      tps=$(awk "BEGIN{printf \"%.1f tok/s\", ${CT}/($wall==0?1:$wall)}")
      record chat "${CHAT_MODEL}" "150-word prompt" "completion" "$wall" "$peak" "$tps" "in ${PT} / out ${CT}"
    else log "  ${RED}✗ chat: no usage in response (see chat.err)${NC}"; fi
  else log "  ${YELLOW}○ chat skipped — set CHAT_URL + CHAT_MODEL (AGH LLM suite endpoint)${NC}"; fi
fi

# ── Render sales-ready Markdown table from CSV ────────────────────────────────
python3 - "$CSV" "$MD" "$GPU_NAME" "$GPU_RATE" <<'PY'
import sys, csv
csv_path, md_path, gpu, rate = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
rows=list(csv.DictReader(open(csv_path)))
cost_col = rate != "0"
with open(md_path,"w") as f:
    f.write(f"# AGH Creative Suite — Performance Sheet\n\n")
    f.write(f"**GPU:** {gpu}  ")
    if cost_col: f.write(f"· **Rate:** ${rate}/GPU-hour")
    f.write("\n\n")
    hdr=["Modality","Model","Input","Output","Time (s)","Peak VRAM (MB)","Throughput","Tokens"]
    if cost_col: hdr.append("Cost ($)")
    f.write("| "+" | ".join(hdr)+" |\n")
    f.write("|"+"|".join(["---"]*len(hdr))+"|\n")
    for r in rows:
        line=[r["modality"],r["model"],r["input"],r["output"],r["wall_s"],r["peak_vram_mb"],r["throughput"],r["tokens"]]
        if cost_col: line.append(r["cost_usd"])
        f.write("| "+" | ".join(x or "—" for x in line)+" |\n")
    f.write("\n> Measured live on the AGH box. Image/video/audio units are steps/frames/seconds; "
            "tokens apply to chat models. Peak VRAM sampled at 1s. "
            "Cost = time × GPU-hour rate.\n")
print("wrote", md_path)
PY

log ""
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"
log "  ${GREEN}${BOLD}Benchmark complete.${NC}"
log "  CSV:  ${CSV}"
log "  Sheet: ${MD}"
log "${BOLD}════════════════════════════════════════════════════════════════${NC}"
