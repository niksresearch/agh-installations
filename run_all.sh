#!/usr/bin/env bash
# AGH Creative Suite — one-shot orchestrator
#
# Runs the whole pipeline with clear staged logging + gates:
#   setup -> verify -> smoke(lite) -> [smoke heavy] -> [benchmark] -> demo
#
# Each stage streams live AND writes its own detail log. A clean stage summary
# (what started, what passed/failed, elapsed) goes to ~/agh-run/run.log.
# If a gate stage (verify / smoke) FAILS, the pipeline stops before the demo.
#
# Usage (run as root):
#   sudo BUNDLE=3 VNC_PASS=YourPass123 HF_TOKEN=hf_xxx bash run_all.sh
#
# Leave it in the background and watch live:
#   sudo BUNDLE=3 VNC_PASS=YourPass123 HF_TOKEN=hf_xxx nohup bash run_all.sh > ~/agh-run/console.log 2>&1 &
#   tail -f ~/agh-run/console.log        # everything, live
#   tail -f ~/agh-run/run.log            # clean stage summary only
#
# Toggles (env, all optional):
#   BUNDLE=3            which bundle (1/2/3)                 [default 3]
#   VNC_PASS=...        desktop password (REQUIRED, min 6)
#   HF_TOKEN=...        FLUX token (optional; else SDXL)
#   GPU_RATE=2.50       $/GPU-hour for benchmark cost        [default 0]
#   RUN_SETUP=1         run provisioning                     [default 1]
#   RUN_VERIFY=1        run verify_bundle (gate)             [default 1]
#   RUN_SMOKE=1         run smoke lite b3 (gate)             [default 1]
#   RUN_SMOKE_HEAVY=0   also run smoke heavy b3              [default 0]
#   RUN_BENCH=0         run benchmark perf sheet             [default 0]
#   RUN_DEMO=1          run the promo demo (final stage)     [default 1]
#   STOP_ON_FAIL=1      stop pipeline if a gate fails        [default 1]
#   RAW=...             GitHub raw base for fetching scripts
set -uo pipefail

RAW="${RAW:-https://raw.githubusercontent.com/niksresearch/agh-installations/main}"
BUNDLE="${BUNDLE:-3}"
HF_TOKEN="${HF_TOKEN:-}"
GPU_RATE="${GPU_RATE:-0}"
RUN_SETUP="${RUN_SETUP:-1}"
RUN_VERIFY="${RUN_VERIFY:-1}"
RUN_SMOKE="${RUN_SMOKE:-1}"
RUN_SMOKE_HEAVY="${RUN_SMOKE_HEAVY:-0}"
RUN_BENCH="${RUN_BENCH:-0}"
RUN_DEMO="${RUN_DEMO:-1}"
STOP_ON_FAIL="${STOP_ON_FAIL:-1}"

BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo BUNDLE=$BUNDLE VNC_PASS=... bash $0"; exit 1; }
[[ -n "${VNC_PASS:-}" && ${#VNC_PASS} -ge 6 ]] || { echo "VNC_PASS required (min 6 chars)."; exit 1; }
[[ "$BUNDLE" =~ ^[123]$ ]] || { echo "BUNDLE must be 1, 2, or 3."; exit 1; }
export BUNDLE VNC_PASS HF_TOKEN GPU_RATE

RUNDIR="${HOME:-/root}/agh-run"
LOG="${RUNDIR}/run.log"
mkdir -p "${RUNDIR}"
PIPE_START=$(date +%s)

# clean stage summary -> console AND run.log
say()  { echo -e "$*"; echo -e "$(echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g')" >> "${LOG}"; }
line() { say "${BOLD}────────────────────────────────────────────────────────────${NC}"; }

# run_stage <name> <detail-logfile> <cmd...>
#   streams live to console + detail log; records OK/FAIL + elapsed to run.log
run_stage() {
  local name="$1" logf="$2"; shift 2
  local t0 rc el
  line
  say "${CYAN}${BOLD}▶ STAGE: ${name}${NC}   $(date '+%H:%M:%S')"
  say "  detail log: ${logf}"
  t0=$(date +%s)
  "$@" 2>&1 | tee "${logf}"
  rc=${PIPESTATUS[0]}
  el=$(( $(date +%s) - t0 ))
  if [[ $rc -eq 0 ]]; then
    say "${GREEN}✓ ${name} OK${NC}  (${el}s)"
  else
    say "${RED}✗ ${name} FAILED (rc=${rc})${NC}  (${el}s) — see ${logf}"
    if [[ "$STOP_ON_FAIL" == "1" ]]; then
      say "${RED}${BOLD}STOP_ON_FAIL=1 — aborting before the demo.${NC}"
      finish; exit $rc
    fi
  fi
  return 0
}

finish() {
  local total=$(( $(date +%s) - PIPE_START ))
  line
  say "  Pipeline time: ${total}s ($(( total/60 ))m $(( total%60 ))s)"
  say "  Logs in: ${RUNDIR}/"
}

# ── Banner ────────────────────────────────────────────────────────────────────
: > "${LOG}"
say "${BOLD}════════════════════════════════════════════════════════════════${NC}"
say "${BOLD}  AGH Creative Suite — full pipeline${NC}"
say "  Started:  $(date '+%Y-%m-%d %H:%M:%S')"
say "  Bundle:   ${BUNDLE}    FLUX token: $( [[ -n "$HF_TOKEN" ]] && echo yes || echo 'no (SDXL fallback)' )"
say "  Stages:   setup=${RUN_SETUP} verify=${RUN_VERIFY} smoke=${RUN_SMOKE} smoke_heavy=${RUN_SMOKE_HEAVY} bench=${RUN_BENCH} demo=${RUN_DEMO}"
say "  Logs:     ${RUNDIR}/"
say "${BOLD}════════════════════════════════════════════════════════════════${NC}"

# ── Precheck: GPU driver ──────────────────────────────────────────────────────
if ! nvidia-smi >/dev/null 2>&1; then
  say "${RED}nvidia-smi fails — GPU driver not ready.${NC}"
  say "Finish drivers first (let cloud-init's nvidia-driver install complete, reboot,"
  say "confirm nvidia-smi), then re-run this script. Aborting."
  exit 1
fi
say "${GREEN}GPU OK:${NC} $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"

# ── Fetch scripts ─────────────────────────────────────────────────────────────
run_stage "fetch scripts" "${RUNDIR}/00-fetch.log" bash -c '
  cd "'"${RUNDIR}"'"
  for s in setup_creative_suite.sh verify_bundle.sh smoke_test.sh benchmark.sh demo_creative_suite_v2.sh; do
    wget -qO "$s" "'"${RAW}"'/$s" && echo "fetched $s" || { echo "FAILED to fetch $s"; exit 1; }
  done'

cd "${RUNDIR}"

# ── 1. Setup ──────────────────────────────────────────────────────────────────
if [[ "$RUN_SETUP" == "1" ]]; then
  run_stage "setup (Bundle ${BUNDLE}, ~20-90 min)" "${RUNDIR}/01-setup.log" bash setup_creative_suite.sh
  # confirm the pod is up before anything else
  if ! ps aux | grep "sleep infinity" | grep -v grep >/dev/null; then
    say "${RED}Pod not running after setup — cannot continue.${NC}"; finish; exit 1
  fi
  say "${GREEN}Pod running.${NC}"
fi

# ── 2. Verify (gate) ──────────────────────────────────────────────────────────
[[ "$RUN_VERIFY" == "1" ]] && run_stage "verify_bundle ${BUNDLE}" "${RUNDIR}/02-verify.log" bash verify_bundle.sh "${BUNDLE}"

# ── 3. Smoke lite (gate) ──────────────────────────────────────────────────────
[[ "$RUN_SMOKE" == "1" ]] && run_stage "smoke lite b3" "${RUNDIR}/03-smoke-lite.log" bash smoke_test.sh lite b3

# ── 4. Smoke heavy (optional) ─────────────────────────────────────────────────
[[ "$RUN_SMOKE_HEAVY" == "1" ]] && run_stage "smoke heavy b3" "${RUNDIR}/04-smoke-heavy.log" bash smoke_test.sh heavy b3

# ── 5. Benchmark (optional) ───────────────────────────────────────────────────
[[ "$RUN_BENCH" == "1" ]] && run_stage "benchmark" "${RUNDIR}/05-benchmark.log" bash benchmark.sh

# ── 6. Demo (final) ───────────────────────────────────────────────────────────
if [[ "$RUN_DEMO" == "1" ]]; then
  # DEMO_LOGGING=1 keeps the demo in the foreground so this stage tracks it fully
  # (the demo still writes its own clean/debug logs under the promo output dir).
  run_stage "demo (promo video)" "${RUNDIR}/06-demo.log" env DEMO_LOGGING=1 bash demo_creative_suite_v2.sh
fi

# ── Done ──────────────────────────────────────────────────────────────────────
line
say "${GREEN}${BOLD}PIPELINE COMPLETE${NC}"
for f in /ephemeral/agh-promo-v2 /opt/agh-promo-v2; do
  [[ -d "$f" ]] && ls -la "$f"/AGH_Creative_Suite_Promo_DirectorsCut.mp4 2>/dev/null | sed 's/^/  /' | tee -a "${LOG}"
done
finish
