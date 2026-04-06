# Troubleshooting Guide

Common issues and solutions for the Ansible AI Agent deployment.

---

## Table of Contents

- [AWS Deployment Issues](#aws-deployment-issues)
- [Worker Connectivity Issues](#worker-connectivity-issues)
- [SSH and Authentication Issues](#ssh-and-authentication-issues)
- [Docker and Container Issues](#docker-and-container-issues)
- [Frontend and ALB Issues](#frontend-and-alb-issues)
- [Ansible Playbook Issues](#ansible-playbook-issues)
- [Metrics and Monitoring Issues](#metrics-and-monitoring-issues)

---

## AWS Deployment Issues

### Terraform Apply Fails with Syntax Errors

**Symptoms**:
```
Error: Invalid character
Error: Argument or block definition required
```

**Cause**: Special characters (em-dash, missing newlines) in Terraform files

**Solution**:
```bash
# Check for em-dash characters
grep -n "—" terraform/*.tf

# Replace with regular hyphens
sed -i 's/—/-/g' terraform/*.tf

# Verify syntax
terraform validate
```

### Workers Not Created in Auto Scaling Group

**Symptoms**: ASG shows 0 instances

**Cause**: Launch template or user data script errors

**Solution**:
```bash
# Check ASG activity
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name ansible-agent-workers \
  --region eu-central-1 \
  --max-records 10

# Check launch template
aws ec2 describe-launch-template-versions \
  --launch-template-name ansible-agent-worker \
  --region eu-central-1
```

### Master EC2 User Data Script Fails

**Symptoms**: Docker containers not running on master

**Solution**:
```bash
# SSH to master and check cloud-init logs
ssh -i ~/.ssh/your-key.pem ec2-user@<MASTER_IP>
sudo cat /var/log/cloud-init-output.log

# Check Docker status
sudo systemctl status docker
docker ps

# Manually run setup if needed
cd /opt/ansible-ai-agent
docker-compose up -d
```

---

## Worker Connectivity Issues

### "Connection refused" on Port 9100

**Symptoms**:
```bash
curl http://10.0.11.191:9100/metrics
curl: (7) Failed to connect to 10.0.11.191 port 9100: Connection refused
```

**Cause**: node_exporter not running on worker

**Solution**:
```bash
# SSH to worker via bastion
ssh -i ~/.ssh/key.pem -o ProxyCommand="ssh -i ~/.ssh/key.pem -W %h:%p ec2-user@<MASTER_IP>" ec2-user@10.0.11.191

# Check service status
sudo systemctl status node_exporter

# If not running, start it
sudo systemctl start node_exporter
sudo systemctl enable node_exporter

# Check if binary exists
ls -la /usr/local/bin/node_exporter

# If missing, reinstall
cd /tmp
curl -sL https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz -o node_exporter.tar.gz
tar xzf node_exporter.tar.gz
sudo cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
sudo systemctl restart node_exporter
```

### "No route to host"

**Symptoms**: Can't reach worker IPs from master

**Cause**: Security group or routing issue

**Solution**:
```bash
# Verify security groups
aws ec2 describe-security-groups \
  --region eu-central-1 \
  --filters "Name=tag:Name,Values=ansible-agent-*" \
  --query 'SecurityGroups[*].[GroupName,GroupId,IpPermissions]'

# Check if workers are in correct subnets
aws ec2 describe-instances \
  --region eu-central-1 \
  --filters "Name=tag:AnsibleGroup,Values=workers" \
  --query 'Reservations[*].Instances[*].[InstanceId,SubnetId,PrivateIpAddress]'

# Test basic connectivity
ping -c 3 10.0.11.191
telnet 10.0.11.191 9100
```

### Workers in Wrong Availability Zones

**Symptoms**: Some workers unreachable

**Cause**: Subnet configuration mismatch

**Solution**: Check Terraform subnet configuration and ensure workers are distributed correctly across AZs.

---

## SSH and Authentication Issues

### "Permission denied (publickey)" from Ansible

**Symptoms**:
```bash
docker exec backend ansible workers -m ping
worker-01 | UNREACHABLE! => {"changed": false, "msg": "Failed to connect: Permission denied (publickey)"}
```

**Cause**: Ansible SSH key not deployed to workers

**Solution**:
```bash
# Verify ansible key exists on master
ssh ec2-user@<MASTER_IP>
cat /opt/ansible-ai-agent/ssh_keys/id_rsa.pub

# Manually deploy to each worker
ssh -i ~/.ssh/terraform-key.pem \
    -o ProxyCommand="ssh -i ~/.ssh/terraform-key.pem -W %h:%p ec2-user@<MASTER_IP>" \
    ec2-user@<WORKER_IP>

# On worker:
sudo mkdir -p /home/ansible/.ssh
echo "<PASTE_ANSIBLE_PUBLIC_KEY>" | sudo tee /home/ansible/.ssh/authorized_keys
sudo chmod 700 /home/ansible/.ssh
sudo chmod 600 /home/ansible/.ssh/authorized_keys
sudo chown -R ansible:ansible /home/ansible/.ssh

# Verify ansible user exists
id ansible
```

### "Host key verification failed"

**Symptoms**:
```
Host key verification failed.
fatal: [worker-01]: UNREACHABLE!
```

**Cause**: Workers not in SSH known_hosts

**Solution**:
```bash
# From master, add workers to known_hosts
docker exec backend ssh-keyscan -H 10.0.11.191 10.0.11.177 10.0.10.139 >> /root/.ssh/known_hosts

# Or disable host key checking (less secure)
docker exec backend bash -c 'echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config'
```

### Ansible SSH Key Has Wrong Permissions

**Symptoms**:
```
Permissions 0644 for '/ansible/ssh_keys/id_rsa' are too open
```

**Solution**:
```bash
# Fix permissions on master
ssh ec2-user@<MASTER_IP>
cd /opt/ansible-ai-agent
chmod 600 ssh_keys/id_rsa
chmod 644 ssh_keys/id_rsa.pub

# Restart backend container
docker-compose restart backend
```

---

## Docker and Container Issues

### Containers Not Starting

**Symptoms**: `docker ps` shows no containers

**Solution**:
```bash
# Check Docker service
sudo systemctl status docker

# Check docker-compose logs
cd /opt/ansible-ai-agent
docker-compose logs

# Try starting manually
docker-compose up -d

# Check for port conflicts
sudo netstat -tulpn | grep -E ':(3000|8000)'
```

### Backend Health Check Failing

**Symptoms**: Container shows "unhealthy" status

**Solution**:
```bash
# Check backend logs
docker-compose logs backend

# Test health endpoint
curl http://localhost:8000/health

# Check if Python dependencies installed
docker exec backend pip list

# Rebuild if needed
docker-compose up -d --build backend
```

### Frontend Build Fails

**Symptoms**:
```
target stage production could not be found
```

**Cause**: Missing production stage in Dockerfile

**Solution**:
```bash
# Update frontend Dockerfile
sudo tee frontend/Dockerfile > /dev/null <<'EOF'
FROM node:20-alpine AS base
WORKDIR /app
COPY package*.json ./
RUN npm ci

FROM base AS dev
COPY . .
EXPOSE 3000
CMD ["npm", "run", "dev"]

FROM base AS production
COPY . .
RUN npm run build
FROM nginx:alpine
COPY --from=production /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 3000
CMD ["nginx", "-g", "daemon off;"]
EOF

# Rebuild
docker-compose up -d --build frontend
```

---

## Frontend and ALB Issues

### "Blocked request" Error in Browser

**Symptoms**:
```
Blocked request. This host ("ansible-agent-alb-xxx.elb.amazonaws.com") is not allowed.
```

**Cause**: Vite dev server blocking ALB hostname

**Solution**:
```bash
# Option 1: Update vite.config.js
cd /opt/ansible-ai-agent/frontend
sudo tee -a vite.config.js > /dev/null <<'EOF'
  server: {
    allowedHosts: 'all',
  }
EOF

# Option 2: Switch to production build (recommended)
cd /opt/ansible-ai-agent
sed -i 's/target: dev/target: production/' docker-compose.yml
docker-compose up -d --build frontend
```

### ALB Returns 502 Bad Gateway

**Symptoms**: Browser shows 502 error

**Cause**: Target group health checks failing

**Solution**:
```bash
# Check target health
aws elbv2 describe-target-health \
  --target-group-arn <TARGET_GROUP_ARN> \
  --region eu-central-1

# Check if containers are running
docker ps

# Check backend logs
docker-compose logs backend

# Verify ports are exposed
docker-compose ps
```

### Can't Access Dashboard via ALB

**Symptoms**: Timeout or connection refused

**Cause**: Security group not allowing traffic

**Solution**:
```bash
# Check ALB security group
aws elbv2 describe-load-balancers \
  --names ansible-agent-alb \
  --region eu-central-1 \
  --query 'LoadBalancers[0].SecurityGroups'

# Verify inbound rules allow port 80
aws ec2 describe-security-groups \
  --group-ids <ALB_SG_ID> \
  --region eu-central-1
```

---

## Ansible Playbook Issues

### Bootstrap Playbook Fails on Amazon Linux 2023

**Symptoms**:
```
TASK [Start and enable node_exporter] ****
fatal: [worker-01]: FAILED! => {"changed": false, "msg": "Could not find the requested service node_exporter"}
```

**Cause**: systemd tasks don't work properly in default AL2023 configuration

**Solution**: Use the manual setup script instead of bootstrap playbook (see AWS_POST_DEPLOY.md)

### Playbook Times Out

**Symptoms**:
```
fatal: [worker-01]: UNREACHABLE! => {"msg": "Failed to connect to the host via ssh: ssh: connect to host 10.0.11.191 port 22: Connection timed out"}
```

**Cause**: SSH connectivity issue

**Solution**:
```bash
# Test SSH manually
docker exec backend ssh -i /ansible/ssh_keys/id_rsa ansible@10.0.11.191

# Check inventory file
docker exec backend cat /ansible/inventory/hosts.ini

# Verify worker IPs are correct
aws ec2 describe-instances \
  --region eu-central-1 \
  --filters "Name=tag:AnsibleGroup,Values=workers" \
  --query 'Reservations[*].Instances[*].PrivateIpAddress'
```

### "Module not found" Errors

**Symptoms**:
```
ERROR! couldn't resolve module/action 'community.general.ufw'
```

**Cause**: Ansible collections not installed

**Solution**:
```bash
# Install collections in backend container
docker exec backend ansible-galaxy collection install community.general
docker exec backend ansible-galaxy collection install ansible.posix
```

---

## Metrics and Monitoring Issues

### No Metrics Showing in Dashboard

**Symptoms**: Dashboard loads but shows no data

**Cause**: Backend can't scrape node_exporter

**Solution**:
```bash
# Test from backend container
docker exec backend curl http://10.0.11.191:9100/metrics

# Check backend logs
docker-compose logs backend | grep -i error

# Verify WebSocket connection
docker-compose logs backend | grep -i websocket

# Test API endpoint
curl http://localhost:8000/api/v1/nodes
```

### Metrics Update Slowly or Not at All

**Symptoms**: Dashboard shows stale data

**Cause**: WebSocket connection issues

**Solution**:
```bash
# Check WebSocket in browser console (F12)
# Should see: WebSocket connection established

# Restart backend
docker-compose restart backend

# Check scrape interval in backend code
docker exec backend grep -r "scrape_interval" /app/
```

### High CPU Usage on Master

**Symptoms**: Master EC2 at 100% CPU

**Cause**: Too frequent scraping or memory leak

**Solution**:
```bash
# Check container resource usage
docker stats

# Increase scrape interval in backend/main.py
# Change from 5s to 10s or 15s

# Restart backend
docker-compose restart backend
```

---

## General Debugging Commands

### Check All Services Status

```bash
# On master EC2
docker-compose ps
docker-compose logs --tail=50

# Check system resources
free -h
df -h
top
```

### Verify Network Connectivity

```bash
# From master to workers
for ip in 10.0.11.191 10.0.11.177 10.0.10.139; do
  echo "Testing $ip..."
  ping -c 2 $ip
  nc -zv $ip 22
  nc -zv $ip 9100
done
```

### Collect Diagnostic Information

```bash
# Run this script to collect all diagnostic info
cat > /tmp/diagnose.sh <<'EOF'
#!/bin/bash
echo "=== Docker Status ==="
docker ps -a

echo -e "\n=== Container Logs ==="
docker-compose logs --tail=20

echo -e "\n=== Network Test ==="
for ip in 10.0.11.191 10.0.11.177 10.0.10.139; do
  curl -s -m 2 http://$ip:9100/metrics | head -n1 || echo "$ip FAILED"
done

echo -e "\n=== Ansible Test ==="
docker exec backend ansible workers -m ping -i /ansible/inventory/hosts.ini

echo -e "\n=== API Test ==="
curl -s http://localhost:8000/api/v1/nodes | jq -r '.[] | .hostname'

echo -e "\n=== System Resources ==="
free -h
df -h
EOF

chmod +x /tmp/diagnose.sh
/tmp/diagnose.sh
```

---

## Getting Help

If you're still stuck:

1. Collect diagnostic information using the script above
2. Check the main README.md for architecture overview
3. Review AWS_POST_DEPLOY.md for deployment steps
4. Check GitHub issues for similar problems
5. Create a new issue with:
   - Error messages
   - Diagnostic output
   - Steps to reproduce
   - AWS region and instance types used
