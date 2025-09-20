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
# Variables
#####################
variable "aws_profile" {
  type        = string
  description = "AWS profile name from ~/.aws/config"
  default     = "training"
}

variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-2"
}

variable "instance_type" {
  description = "EC2 instance type (2 vCPU ~8 GiB)"
  type        = string
  default     = "t3.large"
}

variable "ssh_public_key_path" {
  description = "Path to your local public key"
  type        = string
  default     = "~/.ssh/my_aws.pub"
}

variable "ssh_ingress_cidr" {
  description = "CIDR block allowed to SSH (use your_ip/32 for safety)"
  type        = string
  default     = "0.0.0.0/0"
}

# Kubernetes series from pkgs.k8s.io: e.g., v1.30, v1.29
variable "k8s_series" {
  description = "Kubernetes series for the apt repo (pkgs.k8s.io)"
  type        = string
  default     = "v1.30"
}

#####################
# Provider
#####################
provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project = "LFS258"
      OS      = "Ubuntu 24.04"
    }
  }
}

#####################
# Identity & Region
#####################
data "aws_caller_identity" "me" {}
data "aws_region" "current" {}

#####################
# AMI (Ubuntu 24.04 via SSM)
#####################
data "aws_ssm_parameter" "ubuntu_2404_amd64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

#####################
# Networking
#####################
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "k8s_nodes" {
  name        = "k8s-nodes-sg"
  description = "Security group for Kubernetes lab nodes"
  vpc_id      = data.aws_vpc.default.id

  # SSH (lock to your /32 for real use)
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
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "k8s-nodes-sg" }
}

#####################
# Key Pair
#####################
resource "aws_key_pair" "this" {
  key_name   = "my-aws-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

#####################
# Locals
#####################
locals {
  ubuntu_ami_id = data.aws_ssm_parameter.ubuntu_2404_amd64.value
  subnet_id     = element(data.aws_subnets.default.ids, 0)

  nodes = {
    cp = {
      name     = "k8s-cp-ubuntu-2404"
      hostname = "cp-ubuntu-2404"
      role     = "control-plane"
    }
    worker = {
      name     = "k8s-worker-ubuntu-2404"
      hostname = "worker-ubuntu-2404"
      role     = "worker"
    }
  }

  # Cloud-init template: placeholders are %s for hostname and k8s_series (used twice)
  k8s_user_data = <<-CLOUDCFG
    #cloud-config
    hostname: %s
    preserve_hostname: false
    manage_etc_hosts: true

    write_files:
      - path: /usr/local/bin/apt-retry
        permissions: "0755"
        content: |
          #!/usr/bin/env bash
          set -euo pipefail
          n=0
          until [ "$n" -ge 5 ]; do
            if "$@"; then exit 0; fi
            n=$((n+1)); sleep 5
          done
          exit 1
      - path: /etc/modules-load.d/k8s.conf
        content: |
          overlay
          br_netfilter
      - path: /etc/sysctl.d/99-kubernetes-cri.conf
        content: |
          net.bridge.bridge-nf-call-iptables = 1
          net.bridge.bridge-nf-call-ip6tables = 1
          net.ipv4.ip_forward = 1

    packages:
      - ca-certificates
      - curl
      - gnupg

    runcmd:
      - timedatectl set-timezone UTC

      # Disable swap (kubelet requirement)
      - swapoff -a
      - sed -ri 's/^[^#].*\\sswap\\s/# &/g' /etc/fstab

      # Kernel modules + sysctl
      - modprobe overlay
      - modprobe br_netfilter
      - sysctl --system

      # Install containerd
      - /usr/local/bin/apt-retry apt-get update
      - /usr/local/bin/apt-retry apt-get install -y containerd
      - mkdir -p /etc/containerd
      - bash -lc 'containerd config default > /etc/containerd/config.toml'
      - sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      - systemctl enable --now containerd

      # Kubernetes apt repo (pkgs.k8s.io)
      - install -m 0755 -d /etc/apt/keyrings
      - curl -fsSL https://pkgs.k8s.io/core:/stable:/%s/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      - chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      - bash -lc 'echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/%s/deb/ /" > /etc/apt/sources.list.d/kubernetes.list'

      # Install kubelet, kubeadm, kubectl
      - /usr/local/bin/apt-retry apt-get update
      - /usr/local/bin/apt-retry apt-get install -y kubelet kubeadm kubectl
      - apt-mark hold kubelet kubeadm kubectl

      # Enable kubelet (it will wait for kubeadm)
      - systemctl enable kubelet
  CLOUDCFG
}

#####################
# EC2 Instances (for_each)
#####################
resource "aws_instance" "node" {
  for_each               = local.nodes
  ami                    = local.ubuntu_ami_id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]

  associate_public_ip_address = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Render cloud-init with hostname + k8s series
  user_data = format(local.k8s_user_data, each.value.hostname, var.k8s_series, var.k8s_series)

  # Re-run if user_data changes
  user_data_replace_on_change = true

  tags = {
    Name       = each.value.name
    "k8s-role" = each.value.role
  }
}

#####################
# Readiness Checks (for_each)
#####################
resource "null_resource" "node_ready" {
  for_each = aws_instance.node

  depends_on = [aws_instance.node]

  triggers = {
    instance_id = each.value.id
  }

  connection {
    type        = "ssh"
    host        = each.value.public_ip
    user        = "ubuntu"
    private_key = file(pathexpand("~/.ssh/my_aws"))
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cloud-init status --wait",
      "until command -v kubeadm && command -v kubectl; do sleep 5; done",
      "sudo systemctl is-active --quiet containerd"
    ]
  }
}

#####################
# Outputs
#####################
output "profile" {
  value = var.aws_profile
}

output "region" {
  value = data.aws_region.current.region
}

output "whoami" {
  value = data.aws_caller_identity.me.arn
}

output "ami_id" {
  value     = local.ubuntu_ami_id
  sensitive = true
}

output "nodes" {
  value = {
    for k, inst in aws_instance.node :
    k => {
      public_ip  = inst.public_ip
      private_ip = inst.private_ip
      role       = local.nodes[k].role
      name       = local.nodes[k].name
    }
  }
}