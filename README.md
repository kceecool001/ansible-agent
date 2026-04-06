# Ansible AI Agent

A live infrastructure dashboard powered by a FastAPI backend, React frontend,
Ansible for orchestration, and Claude (Anthropic) as the AI command layer.

**Version 2.0** - Enhanced with security hardening, performance optimizations, and production-ready features.

📚 **Documentation**:
- [docs/AWS_POST_DEPLOY.md](docs/AWS_POST_DEPLOY.md) - Critical post-deployment steps for AWS
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - Common issues and solutions
- [IMPROVEMENTS.md](IMPROVEMENTS.md) - Complete changelog of v2.0 enhancements
- [CONFIG.md](CONFIG.md) - Configuration reference

## Architecture

```
Browser (React)
  ├── REST  /api/*        → FastAPI backend
  ├── WS    /ws/metrics   → Live node metrics (node_exporter scrape)
  └── POST  /api/ai/run   → Claude AI agent

FastAPI backend
  ├── Scrapes node_exporter :9100 on every node every 5s
  ├── Runs ansible-playbook / ad-hoc commands on demand
  └── Calls Anthropic API to interpret natural-language commands

Worker nodes
  └── node_exporter :9100  (installed by bootstrap.yml)
```

---

## Local setup (Docker — 5 minutes)

### Prerequisites
- Docker Desktop (or Docker Engine + Compose)
- An Anthropic API key → https://console.anthropic.com

### Steps

```bash
git clone <this-repo>
cd ansible-ai-agent

# One-command setup
bash scripts/local_setup.sh
```

The script will:
1. Generate an SSH key pair in `ssh_keys/`
2. Ask for your Anthropic API key and save it to `.env`
3. Write a local inventory pointing at Docker container IPs
4. Build and start all containers via Docker Compose
5. Open the dashboard at http://localhost:3000

### Services started

| Service       | URL                        | Description                       |
|---------------|----------------------------|-----------------------------------|
| Dashboard     | http://localhost:3000      | React frontend                    |
| Backend API   | http://localhost:8000      | FastAPI + WebSocket                |
| API docs      | http://localhost:8000/docs | Swagger UI                        |
| worker-01     | http://localhost:9101      | node_exporter metrics              |
| worker-02     | http://localhost:9102      | node_exporter metrics              |
| worker-03     | http://localhost:9103      | node_exporter metrics              |

### Useful commands

```bash
docker-compose logs -f backend     # tail backend logs
docker-compose logs -f frontend    # tail frontend logs
docker-compose down                # stop everything
docker-compose down -v             # stop + remove volumes
```

---

## Connecting to a real Ansible cluster

### 1. Install node_exporter on your real nodes

```bash
# Run from your local machine (requires SSH access to nodes)
ansible-playbook ansible/playbooks/bootstrap.yml \
  -i ansible/inventory/hosts.ini \
  --ask-become-pass
```

### 2. Update the inventory

Edit `ansible/inventory/hosts.ini` with real IPs/hostnames:

```ini
[master]
master-ctrl-01 ansible_host=192.168.1.10 ansible_user=ubuntu

[workers]
worker-node-01 ansible_host=192.168.1.11 ansible_user=ubuntu
worker-node-02 ansible_host=192.168.1.12 ansible_user=ubuntu
```

### 3. Update `.env`

```bash
ANSIBLE_INVENTORY=/ansible/inventory/hosts.ini
```

### 4. Restart the backend

```bash
docker-compose restart backend
```

The dashboard will begin showing real metrics within 5 seconds.

---

## AWS deployment

### Prerequisites
- AWS CLI configured (`aws configure`)
- Terraform >= 1.7 (`brew install terraform` or https://developer.hashicorp.com/terraform/install)
- An EC2 key pair created in your target region

### Quick Start

```bash
# 1. Copy and fill in the variables file
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform/terraform.tfvars with your values

# 2. Plan (dry run)
bash scripts/aws_deploy.sh plan

# 3. Apply (creates all AWS resources — ~5 min)
bash scripts/aws_deploy.sh apply

# 4. Configure workers (CRITICAL - run from your local machine)
MASTER_IP=$(cd terraform && terraform output -raw master_public_ip)
chmod +x scripts/setup_workers_via_bastion.sh
./scripts/setup_workers_via_bastion.sh ~/.ssh/your-terraform-key.pem $MASTER_IP
```

**Important**: The bootstrap playbook does NOT work reliably on Amazon Linux 2023. Use the `setup_workers_via_bastion.sh` script instead.

### Detailed Post-Deployment Steps

After `terraform apply` completes, workers need manual configuration:

1. **The master EC2 runs Docker containers** (backend, frontend)
2. **Workers are real EC2 instances** in private subnets that need:
   - Ansible user with SSH key access
   - node_exporter installed and running

See [docs/AWS_POST_DEPLOY.md](docs/AWS_POST_DEPLOY.md) for complete step-by-step instructions.

### Verification

```bash
# SSH to master
ssh -i ~/.ssh/your-key.pem ec2-user@$MASTER_IP

# Test node_exporter connectivity
for ip in 10.0.11.191 10.0.11.177 10.0.10.139; do
  curl -s http://$ip:9100/metrics | head -n1
done

# Test Ansible connectivity
docker exec backend ansible workers -m ping -i /ansible/inventory/hosts.ini

# Access dashboard via ALB
echo "Dashboard: http://$(cd terraform && terraform output -raw alb_dns_name)"
```

### AWS resources created

| Resource              | Type              | Purpose                         |
|-----------------------|-------------------|---------------------------------|
| VPC + subnets         | Networking        | Isolated network                |
| master EC2 (t3.medium)| EC2               | Runs Docker Compose stack       |
| worker EC2s (t3.small)| Auto Scaling Group| Managed nodes                   |
| Application LB        | ALB               | HTTPS entrypoint + routing      |
| Security groups       | SG                | Port access control             |
| NAT Gateway           | NAT               | Outbound for private workers    |
| Elastic IP            | EIP               | Static IP for master            |
| IAM role              | IAM               | SSM access for master           |

Estimated monthly cost: ~$80-120 (3 workers, us-east-1, on-demand).
Use Spot instances for workers to cut costs by ~70%.

### Teardown

```bash
bash scripts/aws_deploy.sh destroy
```

### Troubleshooting

Common issues:

- **"Connection refused" on port 9100**: node_exporter not running on workers. Re-run setup script.
- **"Permission denied (publickey)"**: Ansible SSH key not deployed. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- **"Blocked request" in browser**: Vite dev server blocking ALB hostname. Switch to production frontend (see post-deploy guide)
- **Dashboard shows no metrics**: Backend can't reach workers. Verify security groups and node_exporter status.

For detailed troubleshooting, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

---

## Available playbooks

| File                             | Description                                    |
|----------------------------------|------------------------------------------------|
| `playbooks/bootstrap.yml`        | Install ansible user + node_exporter on all nodes |
| `playbooks/nginx_deploy.yml`     | Deploy nginx on workers                        |
| `playbooks/patch.yml`            | Rolling OS patch (one node at a time)          |

### Add your own playbook

Drop any `.yml` file into `ansible/playbooks/` and it becomes available
via the dashboard's Quick Actions and the AI agent's run_playbook action.

---

## AI command examples

Type these into the dashboard command bar:

```
run nginx playbook on workers
patch all worker nodes
check disk usage on master
restart nginx on worker-02
show cluster status
what nodes have high memory usage?
install htop on all workers
```

The AI agent (Claude) interprets the command, selects the right playbook
or ad-hoc module, and returns a structured plan before execution.

---

## Project structure

```
ansible-ai-agent/
├── backend/
│   ├── main.py              # FastAPI app (REST + WebSocket + AI)
│   ├── requirements.txt
│   └── Dockerfile
├── frontend/
│   ├── src/
│   │   ├── App.jsx          # Main dashboard
│   │   ├── main.jsx
│   │   └── hooks/
│   │       └── useMetrics.js # WebSocket metrics hook
│   ├── index.html
│   ├── vite.config.js
│   ├── package.json
│   └── Dockerfile
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   ├── hosts.ini        # Production inventory
│   │   └── hosts_local.ini  # Local Docker inventory
│   └── playbooks/
│       ├── bootstrap.yml    # Install node_exporter + ansible user
│       ├── nginx_deploy.yml # Deploy nginx on workers
│       └── patch.yml        # Rolling OS patch
├── terraform/
│   ├── main.tf              # VPC, EC2, ALB, ASG
│   ├── userdata_master.sh.tpl
│   ├── userdata_worker.sh
│   └── terraform.tfvars.example
├── scripts/
│   ├── local_setup.sh       # One-command local dev setup
│   └── aws_deploy.sh        # Terraform plan/apply/destroy wrapper
├── docker-compose.yml
├── .env.example
└── .gitignore
```

---

## Security notes

- Never commit `.env`, `ssh_keys/`, or `terraform.tfvars` to git (covered by `.gitignore`)
- In production, put the Anthropic API key in AWS Secrets Manager and reference it via IAM
- Restrict SSH access (`your_cidr` variable) to your actual IP, not `0.0.0.0/0`
- Enable ALB HTTPS with ACM before exposing publicly — the Terraform `domain_name` variable handles this
- node_exporter port 9100 is SG-restricted to the master only — workers are not publicly reachable
