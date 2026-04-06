#!/bin/bash
set -e

# Run this from your MacBook
# Usage: ./scripts/setup_workers_via_bastion.sh <path-to-terraform-ec2-key.pem> <master-public-ip>

if [ $# -ne 2 ]; then
  echo "Usage: $0 <terraform-key.pem> <master-public-ip>"
  echo "Example: $0 ~/.ssh/my-ec2-key.pem 3.123.45.67"
  exit 1
fi

TERRAFORM_KEY="$1"
MASTER_IP="$2"
REGION="eu-central-1"

WORKERS=(
  "10.0.10.12"
  "10.0.11.189"
  "10.0.11.217"
)

# Get ansible public key from master
echo "Fetching ansible public key from master..."
ANSIBLE_PUB_KEY=$(ssh -i "$TERRAFORM_KEY" -o StrictHostKeyChecking=no ec2-user@$MASTER_IP \
  "cat /opt/ansible-ai-agent/ssh_keys/id_rsa.pub")

echo "Ansible public key: ${ANSIBLE_PUB_KEY:0:50}..."

for WORKER_IP in "${WORKERS[@]}"; do
  echo ""
  echo "=== Configuring worker $WORKER_IP ==="
  
  ssh -i "$TERRAFORM_KEY" \
      -o StrictHostKeyChecking=no \
      -o ProxyCommand="ssh -i $TERRAFORM_KEY -o StrictHostKeyChecking=no -W %h:%p ec2-user@$MASTER_IP" \
      ec2-user@$WORKER_IP << EOF
set -e

# Add ansible user
sudo useradd -m -s /bin/bash ansible 2>/dev/null || true
echo "ansible ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ansible

# Add ansible SSH key
sudo mkdir -p /home/ansible/.ssh
echo "$ANSIBLE_PUB_KEY" | sudo tee /home/ansible/.ssh/authorized_keys
sudo chmod 700 /home/ansible/.ssh
sudo chmod 600 /home/ansible/.ssh/authorized_keys
sudo chown -R ansible:ansible /home/ansible/.ssh

# Install node_exporter
cd /tmp
curl -sL https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz -o node_exporter.tar.gz
tar xzf node_exporter.tar.gz
sudo cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
sudo useradd -rs /bin/false node_exporter 2>/dev/null || true

# Create systemd service
sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<'UNIT'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
UNIT

# Start service
sudo systemctl daemon-reload
sudo systemctl enable node_exporter
sudo systemctl restart node_exporter
sudo systemctl status node_exporter --no-pager

echo "✓ Worker $WORKER_IP configured"
EOF

  echo "✓ Worker $WORKER_IP done"
done

echo ""
echo "=== All workers configured ==="
echo "Testing from master..."

ssh -i "$TERRAFORM_KEY" -o StrictHostKeyChecking=no ec2-user@$MASTER_IP << 'EOF'
cd /opt/ansible-ai-agent
for ip in 10.0.10.12 10.0.11.189 10.0.11.217; do
  echo -n "Testing $ip:9100... "
  curl -s http://$ip:9100/metrics | head -n1
done
EOF
