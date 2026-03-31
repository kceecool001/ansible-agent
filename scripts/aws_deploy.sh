#!/usr/bin/env bash
# scripts/aws_deploy.sh — Deploy to AWS with Terraform
# Usage:  bash scripts/aws_deploy.sh [plan|apply|destroy]

set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'

banner() { echo -e "\n${CYAN}━━━  $1  ━━━${RESET}\n"; }
ok()     { echo -e "${GREEN}✓${RESET}  $1"; }
warn()   { echo -e "${YELLOW}⚠${RESET}  $1"; }
die()    { echo -e "${RED}✗  $1${RESET}" >&2; exit 1; }

ACTION=${1:-plan}
TF_DIR="$(dirname "$0")/../terraform"

banner "Ansible AI Agent — AWS Deploy ($ACTION)"

# ── Pre-flight ────────────────────────────────────────────────────────────
command -v terraform >/dev/null || die "Terraform not found. Install from https://developer.hashicorp.com/terraform/install"
command -v aws       >/dev/null || die "AWS CLI not found. Install from https://aws.amazon.com/cli/"
aws sts get-caller-identity >/dev/null || die "AWS credentials not configured. Run 'aws configure'."
ok "AWS credentials valid"

cd "$TF_DIR"

# ── tfvars check ──────────────────────────────────────────────────────────
if [ ! -f terraform.tfvars ]; then
  warn "terraform.tfvars not found. Copying example…"
  cp terraform.tfvars.example terraform.tfvars
  echo ""
  echo "  Edit terraform/terraform.tfvars, then re-run this script."
  exit 1
fi

# ── Init ──────────────────────────────────────────────────────────────────
banner "Terraform init"
terraform init -upgrade
ok "Initialized"

case "$ACTION" in

  plan)
    banner "Terraform plan"
    terraform plan -out=tfplan
    echo ""
    ok "Plan saved to terraform/tfplan — run 'bash scripts/aws_deploy.sh apply' to deploy."
    ;;

  apply)
    banner "Terraform apply"
    if [ -f tfplan ]; then
      terraform apply tfplan
    else
      terraform apply -auto-approve
    fi
    echo ""
    banner "Deployment complete"
    terraform output
    MASTER_IP=$(terraform output -raw master_public_ip)
    ALB_DNS=$(terraform output -raw alb_dns_name)
    echo ""
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${GREEN}${BOLD}  AWS Deployment Successful!${RESET}"
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  Dashboard  →  ${CYAN}http://${ALB_DNS}${RESET}"
    echo -e "  SSH master →  ${CYAN}ssh ec2-user@${MASTER_IP}${RESET}"
    echo ""
    echo -e "  ${YELLOW}Next:${RESET} Run bootstrap playbook on workers:"
    echo -e "  ${YELLOW}ssh ec2-user@${MASTER_IP} 'cd /opt/ansible-ai-agent && docker-compose exec backend ansible-playbook /ansible/playbooks/bootstrap.yml'${RESET}"
    echo ""
    ;;

  destroy)
    warn "This will destroy all AWS resources for this project."
    read -rp "Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" = "yes" ] || die "Aborted."
    terraform destroy -auto-approve
    ok "All resources destroyed."
    ;;

  *)
    die "Unknown action: $ACTION. Use plan|apply|destroy"
    ;;
esac
