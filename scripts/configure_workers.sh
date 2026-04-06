#!/bin/bash
set -e

REGION="eu-central-1"
ANSIBLE_PUB_KEY=$(cat ssh_keys/id_rsa.pub)

WORKERS=(
  "i-0e743db9fb9662eb9"
  "i-093b81b71865b3abe"
  "i-071c87b4305e8c70b"
)

for INSTANCE_ID in "${WORKERS[@]}"; do
  echo "=== Configuring $INSTANCE_ID ==="
  
  COMMAND_ID=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
      'useradd -m -s /bin/bash ansible 2>/dev/null || true',
      'echo \"ansible ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/ansible',
      'mkdir -p /home/ansible/.ssh',
      'echo \"$ANSIBLE_PUB_KEY\" > /home/ansible/.ssh/authorized_keys',
      'chmod 700 /home/ansible/.ssh',
      'chmod 600 /home/ansible/.ssh/authorized_keys',
      'chown -R ansible:ansible /home/ansible/.ssh',
      'cd /tmp && wget -q https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz',
      'cd /tmp && tar xzf node_exporter-1.8.2.linux-amd64.tar.gz',
      'cp /tmp/node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/',
      'useradd -rs /bin/false node_exporter 2>/dev/null || true',
      'cat > /etc/systemd/system/node_exporter.service <<EOF
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
EOF',
      'systemctl daemon-reload',
      'systemctl enable node_exporter',
      'systemctl restart node_exporter',
      'systemctl status node_exporter'
    ]" \
    --output text --query 'Command.CommandId')
  
  echo "Command sent: $COMMAND_ID"
  echo "Waiting for completion..."
  sleep 5
  
  aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text
  
  echo "✓ Worker $INSTANCE_ID configured"
  echo
done

echo "=== All workers configured ==="
