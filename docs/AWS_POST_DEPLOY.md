# AWS Post-Deployment Setup Guide

This guide covers the critical steps needed after running `terraform apply` to get your Ansible AI Agent fully operational on AWS.

## Overview

After Terraform creates your infrastructure, you need to:
1. Configure SSH access between master and workers
2. Install and start node_exporter on workers
3. Verify connectivity and metrics collection
4. Access the dashboard

**Important**: The master EC2 runs Docker containers (backend, frontend), while workers are real EC2 instances that need manual configuration.

---

## Prerequisites

- Terraform deployment completed successfully
- AWS CLI configured on your local machine
- SSH access to master EC2 (via the Terraform EC2 key pair)
- Master public IP from Terraform output

---

## Step 1: Get Infrastructure Details

From your local machine:

```bash
cd terraform

# Get master public IP
export MASTER_IP=$(terraform output -raw master_public_ip)
echo "Master IP: $MASTER_IP"

# Get ALB DNS name
export ALB_DNS=$(terraform output -raw alb_dns_name)
echo "ALB DNS: $ALB_DNS"

# Get worker instance IDs and IPs
aws ec2 describe-instances \
  --region eu-central-1 \
  --filters "Name=tag:AnsibleGroup,Values=workers" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,State.Name]' \
  --output table
```

---

## Step 2: Configure Workers via Bastion

The workers are in private subnets and need:
- Ansible user with SSH key access
- node_exporter installed and running

### Option A: Automated Script (Recommended)

Run the provided script from your local machine:

```bash
cd /path/to/ansible-ai-agent

# Make script executable
chmod +x scripts/setup_workers_via_bastion.sh

# Run setup (replace with your Terraform key path)
./scripts/setup_workers_via_bastion.sh ~/.ssh/your-terraform-key.pem $MASTER_IP
```

The script will:
1. Fetch the ansible public key from master
2. SSH through master as a jump host to each worker
3. Create ansible user with sudo privileges
4. Deploy ansible SSH public key
5. Download and install node_exporter v1.8.2
6. Create systemd service and start node_exporter
7. Verify connectivity from master

### Option B: Manual Configuration

If the script fails, configure each worker manually:

```bash
# SSH to master first
ssh -i ~/.ssh/your-terraform-key.pem ec2-user@$MASTER_IP

# Get ansible public key
cat /opt/ansible-ai-agent/ssh_keys/id_rsa.pub

# For each worker, SSH via master as jump host
ssh -i ~/.ssh/your-terraform-key.pem \
    -o ProxyCommand="ssh -i ~/.ssh/your-terraform-key.pem -W %h:%p ec2-user@$MASTER_IP" \
    ec2-user@<WORKER_PRIVATE_IP>

# On each worker, run:
sudo useradd -m -s /bin/bash ansible
echo "ansible ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ansible
sudo mkdir -p /home/ansible/.ssh
echo "<PASTE_ANSIBLE_PUBLIC_KEY>" | sudo tee /home/ansible/.ssh/authorized_keys
sudo chmod 700 /home/ansible/.ssh
sudo chmod 600 /home/ansible/.ssh/authorized_keys
sudo chown -R ansible:ansible /home/ansible/.ssh

# Install node_exporter
cd /tmp
curl -sL https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz -o node_exporter.tar.gz
tar xzf node_exporter.tar.gz
sudo cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
sudo useradd -rs /bin/false node_exporter

# Create systemd service
sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<'EOF'
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
EOF

# Start service
sudo systemctl daemon-reload
sudo systemctl enable node_exporter
sudo systemctl start node_exporter
sudo systemctl status node_exporter
```

---

## Step 3: Verify Setup

### 3.1 Test node_exporter Connectivity

From master EC2:

```bash
ssh -i ~/.ssh/your-terraform-key.pem ec2-user@$MASTER_IP

cd /opt/ansible-ai-agent

# Test each worker (replace IPs with your actual worker IPs)
for ip in 10.0.11.191 10.0.11.177 10.0.10.139; do
  echo -n "Testing $ip:9100... "
  curl -s --connect-timeout 3 http://$ip:9100/metrics | head -n1 || echo "FAILED"
done
```

Expected output:
```
Testing 10.0.11.191:9100... # HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
Testing 10.0.11.177:9100... # HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
Testing 10.0.10.139:9100... # HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
```

### 3.2 Test Ansible Connectivity

```bash
docker exec backend ansible workers -m ping -i /ansible/inventory/hosts.ini
```

Expected output:
```
worker-node-01 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
worker-node-02 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
worker-node-03 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

### 3.3 Test Backend API

```bash
curl -s http://localhost:8000/api/v1/nodes | jq
```

Should return metrics for all 3 workers.

### 3.4 Check Docker Containers

```bash
docker-compose ps
```

All containers should show "Up" and "healthy" status.

---

## Step 4: Switch to Production Frontend

The default deployment uses Vite dev server which may have hostname restrictions. Switch to production:

```bash
cd /opt/ansible-ai-agent

# Update docker-compose
sed -i 's/target: dev/target: production/' docker-compose.yml

# Rebuild frontend
docker-compose up -d --build frontend

# Wait for build to complete (~2 minutes)
docker-compose logs -f frontend
```

---

## Step 5: Access Dashboard

Open your browser to the ALB DNS name:

```
http://ansible-agent-alb-XXXXXXXXX.eu-central-1.elb.amazonaws.com
```

You should see:
- Live metrics from all 3 workers updating every 5 seconds
- CPU, memory, disk usage charts
- Node status indicators
- AI command interface

---

## Common Issues

### Issue: "Connection refused" on port 9100

**Cause**: node_exporter not running on workers

**Solution**: 
```bash
# SSH to worker and check service
sudo systemctl status node_exporter
sudo systemctl restart node_exporter
```

### Issue: "Permission denied (publickey)" from Ansible

**Cause**: Ansible SSH key not deployed to workers

**Solution**: Re-run the setup_workers_via_bastion.sh script or manually deploy the key (see Step 2)

### Issue: "Host key verification failed"

**Cause**: Workers not in known_hosts

**Solution**:
```bash
# From master, add workers to known_hosts
docker exec backend ssh-keyscan -H 10.0.11.191 10.0.11.177 10.0.10.139 >> /root/.ssh/known_hosts
```

### Issue: Frontend shows "Blocked request" error

**Cause**: Vite dev server blocking ALB hostname

**Solution**: Switch to production frontend (see Step 4)

### Issue: Backend can't reach workers

**Cause**: Security group misconfiguration

**Solution**: Verify security groups allow port 9100 from master SG to worker SG:
```bash
aws ec2 describe-security-groups \
  --region eu-central-1 \
  --filters "Name=tag:Name,Values=ansible-agent-*" \
  --query 'SecurityGroups[*].[GroupName,GroupId,IpPermissions[*].[FromPort,ToPort,IpProtocol,UserIdGroupPairs[*].GroupId]]'
```

---

## Verification Checklist

- [ ] All 3 workers respond on port 9100
- [ ] Ansible can ping all workers
- [ ] Backend API returns node metrics
- [ ] All Docker containers are healthy
- [ ] Dashboard loads via ALB
- [ ] Live metrics update every 5 seconds
- [ ] AI command interface responds

---

## Next Steps

Once verified:
1. Test AI commands: "check disk usage on workers"
2. Run a playbook: "deploy nginx on workers"
3. Set up HTTPS with ACM certificate (see main README)
4. Configure CloudWatch monitoring
5. Set up automated backups

---

## Cleanup

To destroy all AWS resources:

```bash
cd terraform
terraform destroy -auto-approve
```

This will delete:
- All EC2 instances (master + workers)
- VPC and networking
- ALB and target groups
- Security groups
- IAM roles

**Note**: Terraform state and local files are preserved.
