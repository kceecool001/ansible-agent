# AWS Deployment Lessons Learned

This document captures critical insights from real-world AWS deployment experience to help future deployments succeed on the first try.

---

## Critical Issues Encountered

### 1. Bootstrap Playbook Doesn't Work on Amazon Linux 2023

**Problem**: The `bootstrap.yml` playbook fails when trying to start systemd services on Amazon Linux 2023 EC2 instances.

**Root Cause**: systemd tasks in Ansible don't work reliably on AL2023 in default configuration.

**Solution**: Use the `setup_workers_via_bastion.sh` script instead, which:
- SSHs through master as a jump host
- Manually installs node_exporter
- Creates systemd service files directly
- Starts services using shell commands

**Lesson**: Don't rely on Ansible bootstrap playbooks for initial EC2 configuration. Use user data scripts or manual SSH configuration.

---

### 2. SSH Key Management Between Master and Workers

**Problem**: Ansible SSH keys generated on master aren't automatically deployed to workers.

**Root Cause**: 
- Master generates keys in user data script
- Workers are created by ASG with separate user data
- No mechanism to distribute keys between them

**Solution**: 
- Generate keys on master during user data
- Use bastion script to deploy public key to workers after they're created
- Workers must have ansible user created with proper sudo privileges

**Lesson**: Plan SSH key distribution strategy before deployment. Consider:
- AWS Secrets Manager for key storage
- User data scripts that fetch keys from S3
- EC2 Instance Connect for temporary access

---

### 3. IAM Permissions Insufficient for Worker Management

**Problem**: Master EC2 couldn't use EC2 Instance Connect or SSM to configure workers.

**Root Cause**: Master IAM role only had SSM managed instance policy, not permissions to:
- Send SSH keys via EC2 Instance Connect
- Send commands via SSM
- Describe EC2 instances

**Solution**: Added custom IAM policy with:
```json
{
  "Effect": "Allow",
  "Action": [
    "ec2-instance-connect:SendSSHPublicKey",
    "ec2:DescribeInstances",
    "ssm:SendCommand",
    "ssm:GetCommandInvocation"
  ],
  "Resource": "*"
}
```

**Lesson**: Master EC2 needs broad permissions for worker management. Include all necessary permissions in initial Terraform.

---

### 4. Inventory File Confusion

**Problem**: Multiple inventory files (hosts.ini, hosts_local.ini, hosts_aws.ini) caused confusion about which to use.

**Root Cause**: 
- Local Docker setup uses hosts_local.ini
- AWS deployment generates hosts_aws.ini
- Backend expects hosts.ini

**Solution**: 
- Standardize on hosts.ini for production
- Use hosts_local.ini only for local Docker development
- Update user data script to generate hosts.ini directly

**Lesson**: Use consistent naming conventions. Document which inventory file is used in which environment.

---

### 5. Frontend Vite Dev Server Blocks ALB Hostname

**Problem**: Browser shows "Blocked request" error when accessing via ALB DNS name.

**Root Cause**: Vite dev server has hostname restrictions for security.

**Solution**: 
- Add `allowedHosts: 'all'` to vite.config.js
- OR switch to production build using nginx (recommended)

**Lesson**: Use production builds for any deployment beyond localhost. Dev servers have security restrictions unsuitable for production.

---

### 6. Docker Containers on Master vs Real VMs for Workers

**Problem**: Confusion about architecture - are workers Docker containers or EC2 instances?

**Root Cause**: 
- Local setup uses Docker containers for everything
- AWS setup uses Docker on master, real EC2 for workers
- Documentation didn't clearly distinguish

**Solution**: 
- Clearly document architecture differences
- Local: All Docker containers on one host
- AWS: Docker on master, real EC2 instances for workers

**Lesson**: Explicitly document architecture differences between environments. Don't assume users understand the distinction.

---

### 7. Security Group Verification

**Problem**: Difficult to verify security groups allow correct traffic before testing.

**Root Cause**: No clear verification steps in documentation.

**Solution**: Add verification commands:
```bash
# Check security group rules
aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=ansible-agent-*" \
  --query 'SecurityGroups[*].[GroupName,GroupId,IpPermissions]'

# Test connectivity
nc -zv 10.0.11.191 9100
```

**Lesson**: Include verification steps at each stage of deployment. Don't wait until the end to discover connectivity issues.

---

### 8. Terraform Syntax Errors

**Problem**: Terraform apply failed with syntax errors (em-dash characters, missing newlines).

**Root Cause**: Copy-paste from documentation introduced special characters.

**Solution**: 
- Run `terraform validate` before apply
- Use proper text editors that show special characters
- Add pre-commit hooks to catch syntax errors

**Lesson**: Always validate Terraform before applying. Use CI/CD pipelines to catch errors early.

---

## Best Practices for Future Deployments

### 1. Pre-Deployment Checklist

- [ ] Terraform validated (`terraform validate`)
- [ ] Variables file complete (terraform.tfvars)
- [ ] EC2 key pair exists in target region
- [ ] AWS CLI configured with correct credentials
- [ ] Anthropic API key available
- [ ] SSH key for bastion access ready

### 2. Deployment Order

1. Run `terraform apply`
2. Wait for all resources to be created (~5 min)
3. Verify master EC2 is running and Docker containers are up
4. Run worker configuration script from local machine
5. Verify node_exporter connectivity
6. Verify Ansible connectivity
7. Test dashboard access via ALB
8. Switch to production frontend build

### 3. Verification at Each Stage

**After Terraform Apply**:
```bash
# Check all resources created
terraform output

# Verify master is running
aws ec2 describe-instances --filters "Name=tag:Name,Values=ansible-agent-master"

# Verify workers are running
aws ec2 describe-instances --filters "Name=tag:AnsibleGroup,Values=workers"
```

**After Worker Configuration**:
```bash
# Test node_exporter
curl http://10.0.11.191:9100/metrics

# Test Ansible
docker exec backend ansible workers -m ping
```

**After Dashboard Access**:
```bash
# Test API
curl http://localhost:8000/api/v1/nodes

# Check container health
docker-compose ps
```

### 4. Documentation Requirements

Every deployment guide should include:
- Architecture diagram showing component relationships
- Clear distinction between environments (local vs AWS)
- Step-by-step verification commands
- Common issues and solutions
- Rollback procedures

### 5. Automation Opportunities

Consider automating:
- Worker SSH key deployment via user data + S3
- Security group verification tests
- Post-deployment health checks
- Automatic switch to production frontend
- CloudWatch alarms for service health

---

## Recommended Terraform Improvements

### 1. Add SSM/EC2 Instance Connect to Worker User Data

```bash
# In userdata_worker.sh
# Install SSM agent (usually pre-installed on AL2023)
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# Fetch ansible public key from S3 or Secrets Manager
aws s3 cp s3://your-bucket/ansible-key.pub /tmp/ansible-key.pub
useradd -m ansible
mkdir -p /home/ansible/.ssh
cp /tmp/ansible-key.pub /home/ansible/.ssh/authorized_keys
chmod 600 /home/ansible/.ssh/authorized_keys
chown -R ansible:ansible /home/ansible/.ssh
```

### 2. Add Health Check Endpoints

```python
# In backend/main.py
@app.get("/health/workers")
async def health_workers():
    """Check if all workers are reachable"""
    results = {}
    for node in get_nodes():
        try:
            response = requests.get(f"http://{node}:9100/metrics", timeout=2)
            results[node] = "healthy" if response.ok else "unhealthy"
        except:
            results[node] = "unreachable"
    return results
```

### 3. Add CloudWatch Alarms

```hcl
resource "aws_cloudwatch_metric_alarm" "backend_health" {
  alarm_name          = "ansible-agent-backend-unhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Average"
  threshold           = "1"
  alarm_description   = "Backend target group unhealthy"
  
  dimensions = {
    TargetGroup  = aws_lb_target_group.backend.arn_suffix
    LoadBalancer = aws_lb.main.arn_suffix
  }
}
```

---

## Cost Optimization Tips

1. **Use Spot Instances for Workers**: Save ~70% on worker costs
2. **Right-size Instances**: Monitor actual usage and downsize if possible
3. **Use NAT Instance Instead of NAT Gateway**: Save ~$30/month for dev environments
4. **Enable Auto Scaling**: Scale workers down during off-hours
5. **Use S3 for Terraform State**: Enable versioning for rollback capability

---

## Security Hardening Checklist

- [ ] Restrict SSH access to specific IP (not 0.0.0.0/0)
- [ ] Enable ALB HTTPS with ACM certificate
- [ ] Store Anthropic API key in Secrets Manager
- [ ] Enable VPC Flow Logs
- [ ] Enable CloudTrail for audit logging
- [ ] Use IMDSv2 for EC2 metadata
- [ ] Enable EBS encryption (already done)
- [ ] Rotate SSH keys regularly
- [ ] Use AWS Systems Manager Session Manager instead of SSH
- [ ] Enable GuardDuty for threat detection

---

## Monitoring and Observability

### Recommended CloudWatch Dashboards

1. **Infrastructure Health**
   - EC2 CPU/Memory/Disk
   - ALB request count and latency
   - Target group health

2. **Application Metrics**
   - Backend API response times
   - WebSocket connection count
   - Ansible playbook execution times

3. **Cost Tracking**
   - EC2 instance hours
   - Data transfer costs
   - NAT Gateway usage

### Log Aggregation

Consider using:
- CloudWatch Logs for centralized logging
- AWS X-Ray for distributed tracing
- Prometheus + Grafana for metrics visualization

---

## Disaster Recovery

### Backup Strategy

1. **Terraform State**: Store in S3 with versioning enabled
2. **SSH Keys**: Backup to secure location (not in git)
3. **Configuration**: Store in git (except secrets)
4. **Data**: If using databases, enable automated backups

### Recovery Procedures

1. **Complete Infrastructure Loss**:
   ```bash
   # Restore from Terraform state
   terraform init
   terraform apply
   # Re-run worker configuration script
   ```

2. **Master EC2 Failure**:
   - Terminate instance
   - Terraform will recreate with same configuration
   - Re-run worker configuration if needed

3. **Worker Failure**:
   - ASG automatically replaces failed instances
   - Run worker configuration script for new instances

---

## Future Enhancements

1. **GitOps Integration**: Use Flux or ArgoCD for continuous deployment
2. **Multi-Region**: Deploy across multiple AWS regions for HA
3. **Database Backend**: Store metrics in TimescaleDB or InfluxDB
4. **Authentication**: Add OAuth2/OIDC for dashboard access
5. **RBAC**: Implement role-based access control for AI commands
6. **Audit Logging**: Track all AI commands and playbook executions
7. **Notification System**: Slack/email alerts for critical events
8. **API Rate Limiting**: Protect against abuse (already implemented in v2.0)

---

## Conclusion

The key to successful AWS deployment is:
1. **Clear documentation** of architecture and differences between environments
2. **Verification at each step** rather than waiting until the end
3. **Proper IAM permissions** planned upfront
4. **Manual configuration scripts** as fallback when automation fails
5. **Production-ready builds** rather than dev servers

Use this document as a reference for future deployments and update it with new learnings.
