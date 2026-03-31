#!/usr/bin/env bash
# scripts/local_setup.sh — Full local dev environment in one command
# Usage:  bash scripts/local_setup.sh
# Requires: Docker, Docker Compose, git

set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'

banner() { echo -e "\n${CYAN}━━━  $1  ━━━${RESET}\n"; }
ok()     { echo -e "${GREEN}✓${RESET}  $1"; }
warn()   { echo -e "${YELLOW}⚠${RESET}  $1"; }
die()    { echo -e "${RED}✗  $1${RESET}" >&2; exit 1; }

banner "Ansible AI Agent — Local Setup"

# ── Pre-flight checks ─────────────────────────────────────────────────────
banner "1 / 6  Pre-flight checks"

command -v docker        >/dev/null || die "Docker not found. Install from https://docs.docker.com/get-docker/"
command -v docker-compose>/dev/null || die "Docker Compose not found."
docker info >/dev/null 2>&1         || die "Docker daemon not running. Start Docker Desktop or 'sudo systemctl start docker'."
ok "Docker OK"

# ── SSH key generation ────────────────────────────────────────────────────
banner "2 / 6  SSH key setup"
mkdir -p ssh_keys
if [ ! -f ssh_keys/id_rsa ]; then
  ssh-keygen -t rsa -b 4096 -f ssh_keys/id_rsa -N "" -C "ansible-agent-local"
  ok "SSH key pair generated: ssh_keys/id_rsa"
else
  ok "SSH key pair already exists"
fi
chmod 600 ssh_keys/id_rsa

# ── Environment file ──────────────────────────────────────────────────────
banner "3 / 6  Environment configuration"
if [ ! -f .env ]; then
  cp .env.example .env 2>/dev/null || cat > .env <<'EOF'
# Auto-generated — fill in your Anthropic API key
ANTHROPIC_API_KEY=
ANSIBLE_INVENTORY=/ansible/inventory/hosts_local.ini
SCRAPE_INTERVAL=5
EOF
fi

if ! grep -q "ANTHROPIC_API_KEY=sk-" .env 2>/dev/null; then
  echo ""
  read -rp "  Enter your Anthropic API key (sk-ant-...): " AKEY
  if [[ "$AKEY" == sk-* ]]; then
    sed -i.bak "s|ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=$AKEY|" .env
    ok "API key saved to .env"
  else
    warn "No valid key entered — AI commands will fail. You can edit .env later."
  fi
else
  ok "Anthropic API key already set"
fi

# ── Update local inventory to use docker IPs ──────────────────────────────
banner "4 / 6  Local inventory"
cat > ansible/inventory/hosts_local.ini <<'INI'
[master]
master-ctrl-01 ansible_host=172.28.0.1 ansible_connection=local

[workers]
worker-node-01 ansible_host=172.28.0.11 ansible_connection=local
worker-node-02 ansible_host=172.28.0.12 ansible_connection=local
worker-node-03 ansible_host=172.28.0.13 ansible_connection=local

[all:vars]
ansible_user=root
ansible_python_interpreter=/usr/bin/python3
INI
ok "Local inventory written"

# ── Build & start ─────────────────────────────────────────────────────────
banner "5 / 6  Building Docker images"
docker-compose build --parallel
ok "Images built"

banner "6 / 6  Starting stack"
docker-compose up -d

# ── Wait for health ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Waiting for services to be healthy…${RESET}"
for _ in $(seq 1 30); do
  if curl -sf http://localhost:8000/health >/dev/null 2>&1; then
    ok "Backend healthy at http://localhost:8000"
    break
  fi
  sleep 2
  printf "."
done

echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Ansible AI Agent is running!${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Dashboard  →  ${CYAN}http://localhost:3000${RESET}"
echo -e "  API docs   →  ${CYAN}http://localhost:8000/docs${RESET}"
echo -e "  node_exp   →  ${CYAN}http://localhost:9101/metrics${RESET}  (worker-01)"
echo ""
echo -e "  Logs:   ${YELLOW}docker-compose logs -f${RESET}"
echo -e "  Stop:   ${YELLOW}docker-compose down${RESET}"
echo ""
