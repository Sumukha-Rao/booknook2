# ============================================================================
#  BookNook — AWS deployment in a single Terraform file (with login & admin)
#  Services: VPC, EC2 (+ Auto Scaling), RDS MySQL, S3, CloudFront, ALB, Route 53
#  NOT used: IAM role, Secrets Manager, CloudWatch, ACM.
#
#  Auth note: Terraform generates a random JWT_SECRET and bakes it into the
#  launch template's user-data, so every Auto Scaling instance shares the SAME
#  secret (tokens issued by one instance are accepted by all others).
#
#  QUICK START:
#    1. Put your Git repo link in  var.git_repo_url  (below) ▼▼▼
#    2. terraform init
#    3. terraform apply
#    4. open the cloudfront_url from the outputs, sign in as admin / admin123
#    5. terraform destroy   (to remove everything)
# ============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# ----------------------------------------------------------------------------
#  VARIABLES
# ----------------------------------------------------------------------------

# >>> PUT YOUR GIT REPO LINK HERE <<<
# The ONLY value you must change. EC2 instances clone this repo and run
# /backend (server.js) on first boot. Use an HTTPS URL to a PUBLIC repo.
variable "git_repo_url" {
  description = "HTTPS URL of the BookNook Git repository to deploy"
  type        = string
  default     = "https://github.com/Sumukha-Rao/booknook2.git" # <-- CHANGE THIS
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "booknook"
}

variable "db_username" {
  type    = string
  default = "admin"
}

variable "db_name" {
  type    = string
  default = "booknook"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "frontend_index" {
  description = "Local path to the frontend file to upload to S3 (defaults to <module>/frontend/index.html)"
  type        = string
  default     = ""
}

locals {
  name           = var.project
  tags           = { Project = var.project, ManagedBy = "terraform" }
  frontend_index = var.frontend_index != "" ? var.frontend_index : "${path.module}/frontend/index.html"
}

# ----------------------------------------------------------------------------
#  NETWORK  (VPC, subnets, gateways, routes)
# ----------------------------------------------------------------------------
data "aws_availability_zones" "available" { state = "available" }

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${local.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-igw" })
}

# Public subnets (ALB + NAT) — two AZs
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = ["10.0.0.0/24", "10.0.5.0/24"][count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.name}-public-${count.index}" })
}

# App subnets (EC2) — private
resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = ["10.0.1.0/24", "10.0.2.0/24"][count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = merge(local.tags, { Name = "${local.name}-app-${count.index}" })
}

# DB subnets (RDS) — isolated
resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = ["10.0.3.0/24", "10.0.4.0/24"][count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = merge(local.tags, { Name = "${local.name}-db-${count.index}" })
}

# NAT (so private EC2 can reach the internet for npm / git)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name}-nat-eip" })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(local.tags, { Name = "${local.name}-nat" })
  depends_on    = [aws_internet_gateway.this]
}

# Public route table -> IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${local.name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table -> NAT
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${local.name}-private-rt" })
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

# DB route table -> local only (no internet route)
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-db-rt" })
}

resource "aws_route_table_association" "db" {
  count          = 2
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# ----------------------------------------------------------------------------
#  SECURITY GROUPS  (chain:  internet -> ALB -> EC2 -> RDS)
# ----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name   = "${local.name}-sg-alb"
  vpc_id = aws_vpc.this.id
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.name}-sg-alb" })
}

resource "aws_security_group" "backend" {
  name   = "${local.name}-sg-backend"
  vpc_id = aws_vpc.this.id
  ingress {
    description     = "API port from the ALB only"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.name}-sg-backend" })
}

resource "aws_security_group" "rds" {
  name   = "${local.name}-sg-rds"
  vpc_id = aws_vpc.this.id
  ingress {
    description     = "MySQL from the backend only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.name}-sg-rds" })
}

# ----------------------------------------------------------------------------
#  DATABASE  (RDS MySQL) + generated password
# ----------------------------------------------------------------------------
resource "random_password" "db" {
  length           = 20
  special          = true
  override_special = "!#%*-_=+"
}

# JWT signing secret — generated once and shared by every instance.
# Alphanumeric only (special = false) so it's safe inside the .env heredoc.
resource "random_password" "jwt" {
  length  = 48
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db-subnets"
  subnet_ids = aws_subnet.db[*].id
  tags       = local.tags
}

resource "aws_db_instance" "this" {
  identifier             = "${local.name}-db"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_type           = "gp3"
  db_name                = var.db_name
  username               = var.db_username
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false
  skip_final_snapshot    = true
  deletion_protection    = false
  tags                   = merge(local.tags, { Name = "${local.name}-db" })
}

# ----------------------------------------------------------------------------
#  COMPUTE  (Launch Template + Auto Scaling) — app deploy lives in user-data
# ----------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_launch_template" "this" {
  name_prefix            = "${local.name}-lt-"
  image_id               = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.backend.id]

  # Bootstrap: install Node, clone the repo, write .env (DB creds + the shared
  # JWT secret), and run the API as a systemd service on port 3000.
  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -e
    apt update -y
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs git
    git clone ${var.git_repo_url} /opt/booknook
    cd /opt/booknook/backend
    cat > .env <<ENV
    PORT=3000
    CORS_ORIGIN=*
    JWT_SECRET=${random_password.jwt.result}
    DB_HOST=${aws_db_instance.this.address}
    DB_PORT=3306
    DB_USER=${var.db_username}
    DB_PASSWORD=${random_password.db.result}
    DB_NAME=${var.db_name}
    ENV
    npm install
    cat > /etc/systemd/system/booknook.service <<UNIT
    [Unit]
    Description=BookNook API
    After=network.target
    [Service]
    WorkingDirectory=/opt/booknook/backend
    ExecStart=/usr/bin/node server.js
    Restart=always
    EnvironmentFile=/opt/booknook/backend/.env
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now booknook
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.name}-api" })
  }
}

resource "aws_autoscaling_group" "this" {
  name                = "${local.name}-asg"
  vpc_zone_identifier = aws_subnet.app[*].id
  target_group_arns   = [aws_lb_target_group.this.arn]
  health_check_type   = "ELB"
  desired_capacity    = 2
  min_size            = 2
  max_size            = 4

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-api"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 70
  }
}

# ----------------------------------------------------------------------------
#  LOAD BALANCER  (ALB + target group + listener)
# ----------------------------------------------------------------------------
resource "aws_lb" "this" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = local.tags
}

resource "aws_lb_target_group" "this" {
  name        = "${local.name}-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"
  health_check {
    path                = "/health"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }
  tags = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# ----------------------------------------------------------------------------
#  FRONTEND STORAGE  (private S3 bucket + upload index.html)
# ----------------------------------------------------------------------------
resource "aws_s3_bucket" "frontend" {
  bucket_prefix = "${local.name}-frontend-"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload index.html. The API constant is rewritten to "" so the page calls the
# API same-origin (CloudFront proxies /api/* to the ALB — see below).
resource "aws_s3_object" "index" {
  bucket        = aws_s3_bucket.frontend.id
  key           = "index.html"
  content       = replace(file(local.frontend_index), "http://localhost:3000", "")
  content_type  = "text/html"
  cache_control = "no-cache"
}

# ----------------------------------------------------------------------------
#  CDN  (CloudFront: S3 origin for the site, ALB origin for /api/*)
# ----------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${local.name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "${local.name} distribution"

  origin {
    origin_id                = "s3"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  origin {
    origin_id   = "alb"
    domain_name = aws_lb.this.dns_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  # /api/* -> the ALB, no caching, forward everything (incl. Authorization)
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies { forward = "all" }
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/health"
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = local.tags
}

# Allow only this CloudFront distribution to read the bucket (OAC)
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFront"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.this.arn } }
    }]
  })
}

# ----------------------------------------------------------------------------
#  OUTPUTS
# ----------------------------------------------------------------------------
output "cloudfront_url" {
  description = "Open this in a browser — the BookNook login page"
  value       = "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "alb_dns_name" {
  description = "Direct ALB URL (HTTP) for testing the API"
  value       = "http://${aws_lb.this.dns_name}"
}

output "rds_endpoint" {
  value = aws_db_instance.this.address
}

output "frontend_bucket" {
  value = aws_s3_bucket.frontend.id
}
