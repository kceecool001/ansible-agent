#!/bin/bash
# userdata_worker.sh — bootstraps each worker EC2 on first boot
set -euo pipefail
exec > >(tee /var/log/ansible-worker-bootstrap.log | logger -t ansible-worker) 2>&1

echo "=== Ansible AI Agent — Worker Bootstrap ==="

# ── System packages ────────────────────────────────────────────────────────
dnf update -y
dnf install -y python3 curl

# ── Create ansible user ────────────────────────────────────────────────────
useradd -m -s /bin/bash ansible || true
echo "ansible ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ansible
mkdir -p /home/ansible/.ssh
chmod 700 /home/ansible/.ssh
chown ansible:ansible /home/ansible/.ssh

# The master will push its public key via the bootstrap playbook.
# For initial connectivity, allow ec2-user key (same key pair).
cp /home/ec2-user/.ssh/authorized_keys /home/ansible/.ssh/authorized_keys 2>/dev/null || true
chown ansible:ansible /home/ansible/.ssh/authorized_keys
chmod 600 /home/ansible/.ssh/authorized_keys

# ── Install node_exporter ──────────────────────────────────────────────────
NODE_EXPORTER_VERSION="1.8.0"
curl -sL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
     -o /tmp/ne.tar.gz
tar xzf /tmp/ne.tar.gz -C /tmp/
cp /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
chmod +x /usr/local/bin/node_exporter

cat > /etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=nobody
ExecStart=/usr/local/bin/node_exporter \
  --collector.filesystem.mount-points-exclude='^/(sys|proc|dev|run)($|/)' \
  --web.listen-address=:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable node_exporter --now

echo "=== Worker bootstrap complete — node_exporter running on :9100 ==="
