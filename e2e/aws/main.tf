# Throwaway end-to-end environment: one Ubuntu 24.04 and one RHEL 9 instance in
# the default VPC, reachable over SSH only from the operator's IP, tagged so the
# EC2 dynamic inventory finds them. Create, test, then `terraform destroy`.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "ansible-linux-hardening-e2e"
      Owner     = var.owner
      ManagedBy = "terraform"
      Ephemeral = "true"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "owner" {
  description = "Who launched the test (Owner tag)"
  type        = string
}

variable "admin_cidr" {
  description = "Only source allowed to SSH in, e.g. your public IP /32"
  type        = string
  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and not 0.0.0.0/0."
  }
}

variable "public_key_path" {
  description = "SSH public key installed on the instances"
  type        = string
}

variable "instance_types" {
  description = "Per OS. RHEL needs 2 GB: dnf was OOM-killed on a 1 GB t3.micro."
  type        = map(string)
  default = {
    ubuntu = "t3.micro"
    rhel   = "t3.small"
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_ami" "rhel9" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat
  filter {
    name   = "name"
    values = ["RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3"]
  }
}

resource "aws_key_pair" "e2e" {
  key_name_prefix = "ansible-hardening-e2e-"
  public_key      = file(var.public_key_path)
}

resource "aws_security_group" "e2e" {
  name_prefix = "ansible-hardening-e2e-"
  description = "SSH from the operator, and between test hosts (fail2ban brute-force test)"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "ssh_admin" {
  security_group_id = aws_security_group.e2e.id
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "ssh_between_hosts" {
  security_group_id            = aws_security_group.e2e.id
  referenced_security_group_id = aws_security_group.e2e.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.e2e.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

locals {
  hosts = {
    ubuntu = { ami = data.aws_ssm_parameter.ubuntu.value, os = "ubuntu" }
    rhel   = { ami = data.aws_ami.rhel9.id, os = "rhel" }
  }
}

resource "aws_instance" "host" {
  for_each                    = local.hosts
  ami                         = each.value.ami
  instance_type               = var.instance_types[each.key]
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.e2e.id]
  key_name                    = aws_key_pair.e2e.key_name
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "ansible-hardening-e2e-${each.key}"
    Hardening   = "true" # what the dynamic inventory filters on
    OS          = each.value.os
    Environment = "e2e"
  }
}

output "public_ips" {
  value = { for k, i in aws_instance.host : k => i.public_ip }
}
