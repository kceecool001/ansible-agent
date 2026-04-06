#!/bin/bash
# userdata_master.sh.tpl — bootstraps the master EC2 on first boot
set -euo pipefail
exec > >(tee /var/log/ansible-agent-bootstrap.log | logger -t ansible-agent) 2>&1

echo "=== Ansible AI Agent — Master Bootstrap ==="

# ── System packages ────────────────────────────────────────────────────────
dnf update -y
dnf install -y docker git python3 python3-pip ansible openssh-clients

# ── Docker ────────────────────────────────────────────────────────────────
systemctl enable docker --now
usermod -aG docker ec2-user

# ── Docker Compose ────────────────────────────────────────────────────────
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
     -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# ── Clone / pull application ───────────────────────────────────────────────
# NOTE: User data only creates directory structure and config files
# Application code (backend, frontend, docker-compose.yml) must be deployed separately
# See docs/AWS_POST_DEPLOY.md for deployment instructions
APP_DIR=/opt/ansible-ai-agent
mkdir -p $APP_DIR
cd $APP_DIR

# ── Generate SSH key for Ansible ───────────────────────────────────────────
mkdir -p ssh_keys
if [ ! -f ssh_keys/id_rsa ]; then
  ssh-keygen -t rsa -b 4096 -f ssh_keys/id_rsa -N "" -C "ansible-agent"
fi
chmod 600 ssh_keys/id_rsa
cat ssh_keys/id_rsa.pub   # printed to log so you can distribute to workers

# ── Environment file ───────────────────────────────────────────────────────
cat > .env <<EOF
ANTHROPIC_API_KEY=${anthropic_api_key}
ANSIBLE_INVENTORY=/ansible/inventory/hosts.ini
SCRAPE_INTERVAL=5
EOF

# ── Write dynamic AWS inventory ────────────────────────────────────────────
mkdir -p ansible/inventory
cat > ansible/inventory/hosts.ini <<INVENTORY
[master]
master-ctrl-01 ansible_connection=local

[workers]
$(echo "${worker_ips}" | tr ',' '\n' | awk -F. '{print "worker-" NR " ansible_host=" $0}')

[all:vars]
ansible_user=ansible
ansible_ssh_private_key_file=/ansible/ssh_keys/id_rsa
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
INVENTORY

# ── Start the stack ────────────────────────────────────────────────────────
docker-compose up -d --build

echo "=== Bootstrap complete. Dashboard: http://$(curl -s ifconfig.me):3000 ==="
