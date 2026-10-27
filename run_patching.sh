#!/usr/bin/env bash
###############################################################################
# run_patching.sh
# Fully automated, zero-human-interaction launcher for Windows Server 2025
# patching via Terraform.
#
# Usage:
#   export TF_VAR_admin_password="YourStr0ngP@ss!"
#   export TF_VAR_vpc_id="vpc-xxxxxxxxxxxxxxxxx"
#   export TF_VAR_subnet_id="subnet-xxxxxxxxxxxxxxxxx"
#   ./run_patching.sh [--destroy-after]
#
# Flags:
#   --destroy-after   Destroy the instance after successful patching (for
#                     ephemeral patching pipelines / golden-image baking).
###############################################################################

set -euo pipefail

# ── Configurable defaults ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}"
LOG_DIR="${SCRIPT_DIR}/run_logs"
LOG_FILE="${LOG_DIR}/patching_$(date +%Y%m%d_%H%M%S).log"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
DESTROY_AFTER=false
TF_PLAN_FILE="${TF_DIR}/patching.tfplan"

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --destroy-after) DESTROY_AFTER=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── Logging helpers ───────────────────────────────────────────────────────────
mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }

log "=== Windows Server 2025 Automated Patching ==="
log "Terraform directory : ${TF_DIR}"
log "Log file            : ${LOG_FILE}"
log "Destroy after patch : ${DESTROY_AFTER}"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
log "Running pre-flight checks..."

command -v "${TERRAFORM_BIN}" >/dev/null 2>&1 || {
  err "Terraform binary not found. Install it or set TERRAFORM_BIN env var."
  exit 1
}
# REL-02 FIX: removed python3 dependency; use pure shell/terraform parsing
log "Terraform version: $(${TERRAFORM_BIN} version | head -1)"

for required_var in TF_VAR_admin_password TF_VAR_vpc_id TF_VAR_subnet_id; do
  if [[ -z "${!required_var:-}" ]]; then
    err "Required environment variable '${required_var}' is not set."
    exit 1
  fi
done
log "All required environment variables are set."

# ── Terraform init ────────────────────────────────────────────────────────────
log "Initialising Terraform..."
${TERRAFORM_BIN} -chdir="${TF_DIR}" init \
  -input=false \
  -upgrade \
  -reconfigure

# ── Terraform validate ────────────────────────────────────────────────────────
log "Validating Terraform configuration..."
${TERRAFORM_BIN} -chdir="${TF_DIR}" validate

# ── Terraform plan ────────────────────────────────────────────────────────────
log "Creating execution plan..."
${TERRAFORM_BIN} -chdir="${TF_DIR}" plan \
  -input=false \
  -out="${TF_PLAN_FILE}"

# ── Terraform apply ───────────────────────────────────────────────────────────
log "Applying plan (patching will run automatically inside the VM)..."
${TERRAFORM_BIN} -chdir="${TF_DIR}" apply \
  -input=false \
  -auto-approve \
  "${TF_PLAN_FILE}"

log "Patching completed successfully."

# ── Capture outputs ───────────────────────────────────────────────────────────
log "Fetching Terraform outputs..."
INSTANCE_ID=$(${TERRAFORM_BIN} -chdir="${TF_DIR}" output -raw instance_id 2>/dev/null || echo "N/A")
PUBLIC_IP=$(${TERRAFORM_BIN}   -chdir="${TF_DIR}" output -raw instance_public_ip 2>/dev/null || echo "N/A")
AMI_NAME=$(${TERRAFORM_BIN}    -chdir="${TF_DIR}" output -raw ami_name_used 2>/dev/null || echo "N/A")

log "Instance ID   : ${INSTANCE_ID}"
log "Public IP     : ${PUBLIC_IP}"
log "AMI name used : ${AMI_NAME}"

# ── Optional: destroy after patching (ephemeral / golden-image workflow) ──────
if [[ "${DESTROY_AFTER}" == "true" ]]; then
  warn "Destroying instance as requested by --destroy-after flag..."
  ${TERRAFORM_BIN} -chdir="${TF_DIR}" destroy \
    -input=false \
    -auto-approve
  log "Instance destroyed."
fi

# ── Cleanup plan file ─────────────────────────────────────────────────────────
rm -f "${TF_PLAN_FILE}"

log "=== All done. Log saved to: ${LOG_FILE} ==="
exit 0
