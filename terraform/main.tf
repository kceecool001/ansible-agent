################################################################################
#  Ansible AI Agent — AWS Infrastructure
#  terraform apply → spins up VPC, master EC2, worker ASG, ALB, Route 53
################################################################################

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
  # Uncomment for remote state (recommended for teams)
  # backend "s3" {
  #   bucket = "your-tf-state-bucket"
  #   key    = "ansible-agent/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "ansible-ai-agent"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

################################################################################
#  Variables
################################################################################

variable "aws_region"       { default = "eu-central-1" }
variable "environment"      { default = "production" }
variable "key_pair_name"    { description = "EC2 key pair for SSH access" }
variable "anthropic_api_key" {
  description = "Anthropic API key"
  sensitive   = true
}
variable "your_cidr"        { description = "Your IP CIDR for SSH access, e.g. 1.2.3.4/32" }
variable "worker_count"     { default = 3 }
variable "master_instance"  { default = "t3.medium" }
variable "worker_instance"  { default = "t3.small" }
variable "domain_name" {
  default     = ""
  description = "Optional: yourdomain.com for Route53/ACM"
}

data "aws_availability_zones" "available" {}

# Latest Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

################################################################################
#  VPC + Networking
################################################################################

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway for private subnets
resource "aws_eip" "nat" { domain = "vpc" }

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

################################################################################
#  Security Groups
################################################################################

resource "aws_security_group" "alb" {
  name        = "ansible-agent-alb"
  description = "Allow HTTP/HTTPS inbound to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "master" {
  name        = "ansible-agent-master"
  description = "Master controller - API, WS, SSH"
  vpc_id      = aws_vpc.main.id

  # SSH from your IP only
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_cidr]
  }
  # FastAPI backend from ALB
  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  # React frontend from ALB
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  # Internal VPC access
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "workers" {
  name        = "ansible-agent-workers"
  description = "Worker nodes - SSH from master, node_exporter from master"
  vpc_id      = aws_vpc.main.id

  # SSH from master only
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.master.id]
  }
  # node_exporter metrics from master
  ingress {
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [aws_security_group.master.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

################################################################################
#  IAM Role for master EC2
################################################################################

resource "aws_iam_role" "master" {
  name = "ansible-agent-master-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.master.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Additional policy for EC2 Instance Connect and worker management
resource "aws_iam_role_policy" "master_additional" {
  name = "ansible-agent-master-additional"
  role = aws_iam_role.master.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2-instance-connect:SendSSHPublicKey",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:DescribeInstanceInformation"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "master" {
  name = "ansible-agent-master-profile"
  role = aws_iam_role.master.name
}

################################################################################
#  Master EC2 (controller)
################################################################################

resource "aws_instance" "master" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.master_instance
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.master.id]
  key_name               = var.key_pair_name
  iam_instance_profile   = aws_iam_instance_profile.master.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata_master.sh.tpl", {
    anthropic_api_key = var.anthropic_api_key
    worker_ips        = join(",", [for i in range(var.worker_count) : "10.0.10.${i + 10}"])
  }))

  tags = { Name = "ansible-agent-master" }
}

resource "aws_eip" "master" {
  instance = aws_instance.master.id
  domain   = "vpc"
}

################################################################################
#  Worker Launch Template + Auto Scaling Group
################################################################################

resource "aws_launch_template" "worker" {
  name_prefix   = "ansible-agent-worker-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.worker_instance
  key_name      = var.key_pair_name

  vpc_security_group_ids = [aws_security_group.workers.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(file("${path.module}/userdata_worker.sh"))

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "ansible-agent-worker" }
  }
}

resource "aws_autoscaling_group" "workers" {
  name                = "ansible-agent-workers"
  desired_capacity    = var.worker_count
  min_size            = 1
  max_size            = 10
  vpc_zone_identifier = aws_subnet.private[*].id

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 120

  tag {
    key                 = "AnsibleGroup"
    value               = "workers"
    propagate_at_launch = true
  }
}

################################################################################
#  Application Load Balancer
################################################################################

resource "aws_lb" "main" {
  name               = "ansible-agent-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "backend" {
  name     = "ansible-agent-backend"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "frontend" {
  name     = "ansible-agent-frontend"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path = "/"
    port = 3000
  }
}

resource "aws_lb_target_group_attachment" "master_backend" {
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = aws_instance.master.id
  port             = 8000
}

resource "aws_lb_target_group_attachment" "master_frontend" {
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = aws_instance.master.id
  port             = 3000
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern { values = ["/api/*", "/ws/*", "/health"] }
  }
}

################################################################################
#  Dynamic inventory script (written to S3 for master to pull)
################################################################################

resource "aws_s3_bucket" "artifacts" {
  bucket = "ansible-agent-artifacts-${data.aws_caller_identity.current.account_id}"
}

data "aws_caller_identity" "current" {}

################################################################################
#  Outputs
################################################################################

output "master_public_ip"  { value = aws_eip.master.public_ip }
output "alb_dns_name"      { value = aws_lb.main.dns_name }
output "dashboard_url"     { value = "http://${aws_lb.main.dns_name}" }
output "ssh_to_master"     { value = "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_eip.master.public_ip}" }
