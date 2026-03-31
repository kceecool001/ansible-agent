# Configuration Reference

## Environment Variables

### Backend Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | (required) | Your Anthropic API key for Claude |
| `ANSIBLE_DIR` | `/ansible` | Base directory for Ansible files |
| `ANSIBLE_INVENTORY` | `/ansible/inventory/hosts.ini` | Path to inventory file |
| `SCRAPE_INTERVAL` | `5` | Seconds between node_exporter scrapes |
| `SCRAPE_TIMEOUT` | `3.0` | Timeout for node_exporter HTTP requests |
| `PLAYBOOK_TIMEOUT` | `300` | Max seconds for playbook execution |
| `ADHOC_TIMEOUT` | `60` | Max seconds for ad-hoc commands |
| `AI_TIMEOUT` | `30.0` | Timeout for Anthropic API requests |

### Frontend Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `VITE_API_URL` | `http://localhost:8000` | Backend API base URL |
| `VITE_WS_URL` | `ws://localhost:8000` | WebSocket URL for metrics |

## Rate Limits

| Endpoint | Limit | Window |
|----------|-------|--------|
| `/api/v1/playbook/run` | 10 requests | per minute |
| `/api/v1/ai/run` | 20 requests | per minute |
| `/api/v1/adhoc` | 15 requests | per minute |

## API Endpoints

### v1 Endpoints (Recommended)

```bash
# Run playbook
POST /api/v1/playbook/run
{
  "playbook": "nginx_deploy.yml",
  "limit": "workers",
  "extra_vars": {}
}

# AI command
POST /api/v1/ai/run
{
  "prompt": "check disk usage on all nodes",
  "context": {}
}

# Ad-hoc command
POST /api/v1/adhoc
{
  "module": "ping",
  "args": "",
  "limit": "all"
}
```

### Legacy Endpoints (Backward Compatible)

```bash
POST /api/playbook/run
POST /api/ai/run
POST /api/adhoc
```

## Allowed Ansible Modules

For security, only these modules are whitelisted for ad-hoc commands:

- `ping` - Test connectivity
- `shell` - Execute shell commands
- `command` - Execute commands without shell
- `copy` - Copy files
- `file` - Manage files/directories
- `service` - Manage services
- `package` - Manage packages
- `user` - Manage users
- `setup` - Gather facts
- `debug` - Print debug messages

## Health Check Endpoints

```bash
# Backend health
GET /health
Response: {"status": "ok", "ts": 1234567890.123}

# Frontend (via browser)
GET /
```

## Docker Compose Health Checks

Services now include health checks:

```yaml
backend:
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
    interval: 10s
    timeout: 5s
    retries: 3
    start_period: 10s

frontend:
  healthcheck:
    test: ["CMD", "wget", "--spider", "http://localhost:3000"]
    interval: 10s
    timeout: 5s
    retries: 3
    start_period: 15s
```

## Performance Tuning

### For High-Volume Deployments

```bash
# Increase connection pool size
# Edit backend/main.py:
http_client = httpx.AsyncClient(
    timeout=httpx.Timeout(SCRAPE_TIMEOUT),
    limits=httpx.Limits(
        max_keepalive_connections=50,  # Increase from 20
        max_connections=100             # Increase from 50
    )
)

# Reduce scrape interval for faster updates
SCRAPE_INTERVAL=3

# Increase rate limits
# Edit backend/main.py limiter decorators
@limiter.limit("30/minute")  # Increase from 10/minute
```

### For Large Node Fleets (50+ nodes)

```bash
# Increase timeouts
SCRAPE_TIMEOUT=5.0
PLAYBOOK_TIMEOUT=600

# Consider batching scrapes
# Modify metrics_loop() to scrape in batches of 20
```

## Security Best Practices

1. **Never commit secrets**:
   ```bash
   # Always in .gitignore
   .env
   ssh_keys/
   terraform.tfvars
   ```

2. **Use AWS Secrets Manager in production**:
   ```python
   # Instead of environment variable
   import boto3
   client = boto3.client('secretsmanager')
   api_key = client.get_secret_value(SecretId='anthropic-api-key')
   ```

3. **Restrict SSH access**:
   ```hcl
   # terraform/terraform.tfvars
   your_cidr = "1.2.3.4/32"  # Your IP only, not 0.0.0.0/0
   ```

4. **Enable HTTPS with ACM**:
   ```hcl
   # terraform/terraform.tfvars
   domain_name = "ansible.yourdomain.com"
   ```

## Troubleshooting

### Backend not starting

```bash
# Check logs
docker-compose logs backend

# Common issues:
# - Missing ANTHROPIC_API_KEY
# - Invalid inventory file
# - Port 8000 already in use
```

### High memory usage

```bash
# Reduce connection pool
# Edit backend/main.py
limits=httpx.Limits(max_keepalive_connections=10, max_connections=20)

# Increase scrape interval
SCRAPE_INTERVAL=10
```

### Rate limit errors

```bash
# Increase limits in backend/main.py
@limiter.limit("50/minute")

# Or disable for development
# Comment out @limiter.limit() decorators
```

### WebSocket disconnections

```bash
# Check frontend logs
docker-compose logs frontend

# Verify backend is healthy
curl http://localhost:8000/health

# Check network connectivity
# WebSocket will auto-reconnect with exponential backoff
```

## Monitoring

### Key Metrics to Watch

```bash
# Backend response times
curl -w "@curl-format.txt" http://localhost:8000/health

# Node scrape success rate
# Check logs for "unreachable" status

# Memory usage
docker stats ansible-agent-backend

# Connection pool utilization
# Add logging to http_client in main.py
```

### Recommended Monitoring Stack

```yaml
# Add to docker-compose.yml
prometheus:
  image: prom/prometheus
  ports:
    - "9090:9090"
  volumes:
    - ./prometheus.yml:/etc/prometheus/prometheus.yml

grafana:
  image: grafana/grafana
  ports:
    - "3001:3000"
```

## Backup & Recovery

### Backup Inventory

```bash
# Automated backup
cp ansible/inventory/hosts.ini ansible/inventory/hosts.ini.backup.$(date +%Y%m%d)
```

### Backup Terraform State

```bash
# If using local state
cp terraform/terraform.tfstate terraform/terraform.tfstate.backup

# If using S3 backend (recommended)
# State is automatically versioned in S3
```

### Disaster Recovery

```bash
# Rebuild from scratch
docker-compose down -v
bash scripts/local_setup.sh

# Restore inventory
cp ansible/inventory/hosts.ini.backup ansible/inventory/hosts.ini

# Restart
docker-compose up -d
```
