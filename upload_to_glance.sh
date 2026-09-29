#!/usr/bin/env bash
# AGH Secure Pods - Glance Image Upload Script
# Run from your OpenStack client machine (NOT inside the VM).
#
# Two workflows supported:
#   1. Snapshot a stopped VM → upload to Glance   (--from-server)
#   2. Upload a local .qcow2 disk image           (--from-file)
#
# Usage:
#   bash upload_to_glance.sh --from-server <server-id-or-name>
#   bash upload_to_glance.sh --from-file   <path/to/image.qcow2>
#
# Prereqs:
#   - python3-openstackclient installed
#   - OpenStack RC file sourced  (source ~/openrc.sh)  OR  OS_* env vars set
set -euo pipefail

# ── Defaults (override via env or args) ──────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-agh-secure-pods-base}"
IMAGE_VISIBILITY="${IMAGE_VISIBILITY:-private}"   # private | shared | public
DISK_FORMAT="${DISK_FORMAT:-qcow2}"
CONTAINER_FORMAT="${CONTAINER_FORMAT:-bare}"

# OpenStack image properties for GPU VMs
HW_VIRT_TYPE="${HW_VIRT_TYPE:-kvm}"
HW_DISK_BUS="${HW_DISK_BUS:-virtio}"
HW_VIF_MODEL="${HW_VIF_MODEL:-virtio}"
HW_VIDEO_MODEL="${HW_VIDEO_MODEL:-virtio}"

# ── Colour helpers ────────────────────────────────────────────────────────────
log()  { echo -e "\n\033[1;34m[$(date '+%H:%M:%S')] $*\033[0m"; }
ok()   { echo -e "\033[1;32m✓ $*\033[0m"; }
die()  { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }
warn() { echo -e "\033[1;33mWARN: $*\033[0m"; }

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage:
  bash upload_to_glance.sh --from-server <server-id|name>  [options]
  bash upload_to_glance.sh --from-file   <image.qcow2>      [options]

Options:
  --name        <name>     Glance image name          (default: ${IMAGE_NAME})
  --visibility  <v>        private | shared | public  (default: ${IMAGE_VISIBILITY})
  --tag         <tag>      Extra tag (repeatable)
  --min-ram     <MB>       Minimum RAM constraint
  --min-disk    <GB>       Minimum disk constraint

Environment:
  IMAGE_NAME, IMAGE_VISIBILITY — same as --name / --visibility
  OS_* variables from your openrc.sh

Examples:
  source ~/openrc.sh
  bash upload_to_glance.sh --from-server agh-bake-vm
  bash upload_to_glance.sh --from-file   /tmp/agh-base.qcow2 --name agh-secure-pods-base-v2
EOF
    exit 1
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
MODE=""
SOURCE=""
EXTRA_TAGS=()
MIN_RAM=""
MIN_DISK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-server)  MODE="server"; SOURCE="$2"; shift 2 ;;
        --from-file)    MODE="file";   SOURCE="$2"; shift 2 ;;
        --name)         IMAGE_NAME="$2";         shift 2 ;;
        --visibility)   IMAGE_VISIBILITY="$2";   shift 2 ;;
        --tag)          EXTRA_TAGS+=("$2");       shift 2 ;;
        --min-ram)      MIN_RAM="$2";             shift 2 ;;
        --min-disk)     MIN_DISK="$2";            shift 2 ;;
        -h|--help)      usage ;;
        *)              die "Unknown argument: $1" ;;
    esac
done

[[ -z "${MODE}" ]] && usage

# ── Preflight checks ──────────────────────────────────────────────────────────
log "Preflight checks"

command -v openstack &>/dev/null || die "'openstack' CLI not found. Install: pip install python-openstackclient"

# Verify OpenStack credentials are set
[[ -n "${OS_AUTH_URL:-}" ]] || die "OpenStack credentials not sourced. Run: source ~/openrc.sh"

echo "OpenStack endpoint : ${OS_AUTH_URL}"
echo "Project            : ${OS_PROJECT_NAME:-${OS_TENANT_NAME:-<not set>}}"
echo "User               : ${OS_USERNAME:-<not set>}"

# Quick connectivity test
log "Verifying OpenStack connectivity"
openstack token issue -f value -c id > /dev/null || die "OpenStack authentication failed"
ok "Authentication OK"

# ── Workflow A: snapshot from running/stopped server ─────────────────────────
snapshot_from_server() {
    local server="${SOURCE}"
    log "Checking server '${server}'"

    local server_status
    server_status=$(openstack server show "${server}" -f value -c status 2>/dev/null) \
        || die "Server '${server}' not found"

    echo "Server status: ${server_status}"

    if [[ "${server_status}" != "SHUTOFF" ]]; then
        warn "Server is '${server_status}', not SHUTOFF. Stopping it now..."
        openstack server stop "${server}"
        echo -n "Waiting for SHUTOFF"
        for _ in $(seq 1 30); do
            sleep 5
            server_status=$(openstack server show "${server}" -f value -c status)
            [[ "${server_status}" == "SHUTOFF" ]] && break
            echo -n "."
        done
        echo ""
        [[ "${server_status}" == "SHUTOFF" ]] || die "Server did not shut down in time"
        ok "Server stopped"
    fi

    log "Creating Nova snapshot → '${IMAGE_NAME}'"
    local snapshot_id
    snapshot_id=$(openstack server image create \
        --name "${IMAGE_NAME}" \
        "${server}" \
        -f value -c id)

    echo "Snapshot ID: ${snapshot_id}"
    echo -n "Waiting for snapshot to become active"
    local img_status=""
    for _ in $(seq 1 60); do
        sleep 10
        img_status=$(openstack image show "${snapshot_id}" -f value -c status)
        [[ "${img_status}" == "active" ]] && break
        echo -n "."
    done
    echo ""
    [[ "${img_status}" == "active" ]] || die "Snapshot did not become active (status: ${img_status})"
    ok "Snapshot active"

    echo "${snapshot_id}"
}

# ── Workflow B: upload from local qcow2 file ──────────────────────────────────
upload_from_file() {
    local file="${SOURCE}"
    [[ -f "${file}" ]] || die "File not found: ${file}"

    local file_size_mb
    file_size_mb=$(( $(stat -f%z "${file}" 2>/dev/null || stat -c%s "${file}") / 1024 / 1024 ))
    log "Uploading '${file}' (${file_size_mb} MB) to Glance as '${IMAGE_NAME}'"

    local image_id
    image_id=$(openstack image create \
        --disk-format  "${DISK_FORMAT}" \
        --container-format "${CONTAINER_FORMAT}" \
        --visibility   "${IMAGE_VISIBILITY}" \
        --file         "${file}" \
        "${IMAGE_NAME}" \
        -f value -c id)

    ok "Upload complete. Image ID: ${image_id}"
    echo "${image_id}"
}

# ── Run selected workflow ─────────────────────────────────────────────────────
IMAGE_ID=""
case "${MODE}" in
    server) IMAGE_ID=$(snapshot_from_server) ;;
    file)   IMAGE_ID=$(upload_from_file)     ;;
esac

# ── Set GPU / AGH metadata properties ────────────────────────────────────────
log "Setting image properties on ${IMAGE_ID}"

openstack image set "${IMAGE_ID}" \
    --property hw_virt_type="${HW_VIRT_TYPE}" \
    --property hw_disk_bus="${HW_DISK_BUS}" \
    --property hw_vif_model="${HW_VIF_MODEL}" \
    --property hw_video_model="${HW_VIDEO_MODEL}" \
    --property hw_qemu_guest_agent=yes \
    --property os_distro=ubuntu \
    --property os_version=22.04 \
    --property agh_image_type=secure-pods-base \
    --property agh_envpod=true \
    --property agh_gpu_ready=true \
    --tag agh-secure-pods \
    --tag gpu-ready

# Apply any extra tags
for tag in "${EXTRA_TAGS[@]:-}"; do
    [[ -n "${tag}" ]] && openstack image set "${IMAGE_ID}" --tag "${tag}"
done

# Apply RAM / disk hints if provided
[[ -n "${MIN_RAM}"  ]] && openstack image set "${IMAGE_ID}" --min-ram  "${MIN_RAM}"
[[ -n "${MIN_DISK}" ]] && openstack image set "${IMAGE_ID}" --min-disk "${MIN_DISK}"

# Set visibility (snapshot workflow keeps it private by default; promote here)
openstack image set "${IMAGE_ID}" --"${IMAGE_VISIBILITY}"

# ── Final summary ─────────────────────────────────────────────────────────────
log "=== Upload complete ==="
openstack image show "${IMAGE_ID}" \
    -f table \
    -c id -c name -c status -c visibility \
    -c disk_format -c size -c properties

echo ""
echo "Image ID   : ${IMAGE_ID}"
echo "Image name : ${IMAGE_NAME}"
echo ""
echo "Launch a GPU VM from this image:"
echo "  openstack server create \\"
echo "    --flavor <gpu-flavor> \\"
echo "    --image  ${IMAGE_ID} \\"
echo "    --network <network-name> \\"
echo "    --key-name <keypair> \\"
echo "    agh-gpu-vm-01"
