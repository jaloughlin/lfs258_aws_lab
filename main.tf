terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

#####################
# Variables (edit me)
#####################
variable "aws_profile" {
  type        = string
  description = "AWS profile name from ~/.aws/config"
  default     = "training"
}

variable "region" {
  description = "AWS region to deploy into"
  type        = string
  # London by default since you're UK-based; change as needed.
  default     = "eu-west-2"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  # 2 vCPU ~8 GiB RAM (closest to 7.5G requested)
  default     = "t3.large"
}

variable "ssh_public_key_path" {
  description = "Path to your local public key"
  type        = string
  default     = "~/.ssh/my_aws.pub"
}

# Your IP in CIDR form for SSH (edit to your current public IP)
variable "ssh_ingress_cidr" {
  description = "CIDR block allowed to SSH"
  type        = string
  default     = "0.0.0.0/0" # Replace with "X.X.X.X/32" for better security
}

provider "aws" {
  region = var.region
}

############################################
# Import your public key as an AWS key pair
############################################
resource "aws_key_pair" "this" {
  key_name   = "my-aws-key"
  public_key = file(var.ssh_public_key_path)
}

############################################
# Get current region
############################################
data "aws_caller_identity" "me" {}
data "aws_region" "current" {}

# Latest Ubuntu 24.04 LTS (Noble) via SSM Parameter (amd64/x86_64)
data "aws_ssm_parameter" "ubuntu_2404_amd64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

##########################
# Networking / Security
##########################
resource "aws_security_group" "k8s_nodes" {
  name        = "k8s-nodes-sg"
  description = "Security group for Kubernetes lab nodes"
  vpc_id      = data.aws_vpc.default.id

  # SSH from your IP (edit ssh_ingress_cidr)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  # Allow all traffic within the SG (node-to-node)
  ingress {
    description = "All intra-SG traffic (node-to-node)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Egress to anywhere
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "k8s-nodes-sg"
  }
}

# Use the default VPC + a default subnet in your region
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  subnet_id = element(data.aws_subnets.default.ids, 0)
  common_tags = {
    Project = "LFS258"
    OS      = "Ubuntu 24.04"
  }
  ubuntu_ami_id = data.aws_ssm_parameter.ubuntu_2404_amd64.value
}

##########################
# EC2 Instances
##########################
# Control plane
resource "aws_instance" "control_plane" {
  ami                    = local.ubuntu_ami_id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    delete_on_termination = true
  }

  # Optional: set hostname; do your own kubeadm steps later
  user_data = <<-EOF
              #cloud-config
              preserve_hostname: false
              hostname: cp-ubuntu-2404
              manage_etc_hosts: true
              runcmd:
                - timedatectl set-timezone UTC
                - swapoff -a || true
              EOF

  tags = merge(local.common_tags, {
    Name     = "k8s-cp-ubuntu-2404"
    "k8s-role" = "control-plane"
  })
}

# Worker
resource "aws_instance" "worker" {
  ami                    = local.ubuntu_ami_id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
              #cloud-config
              preserve_hostname: false
              hostname: worker-ubuntu-2404
              manage_etc_hosts: true
              runcmd:
                - timedatectl set-timezone UTC
                - swapoff -a || true
              EOF

  tags = merge(local.common_tags, {
    Name      = "k8s-worker-ubuntu-2404"
    "k8s-role"  = "worker"
  })
}

##########################
# Outputs
##########################
output "control_plane_public_ip" {
  value = aws_instance.control_plane.public_ip
}

output "control_plane_private_ip" {
  value = aws_instance.control_plane.private_ip
}

output "profile" {
  value = var.aws_profile
}

output "region" {
  value = data.aws_region.current.region
}

output "whoami" {
  value = data.aws_caller_identity.me.arn
}

output "worker_public_ip" {
  value = aws_instance.worker.public_ip
}

output "worker_private_ip" {
  value = aws_instance.worker.private_ip
}
