terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_iam_role" "app_server_role" {
  name = "izac-app-server-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "read_github_key" {
  name = "read-github-deploy-key"
  role = aws_iam_role.app_server_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:us-east-1:259623827663:secret:github-deploy-key*"
    }]
  })
}

resource "aws_iam_instance_profile" "app_server_profile" {
  name = "izac-app-server-profile"
  role = aws_iam_role.app_server_role.name
}

resource "aws_key_pair" "izac_key" {
  key_name   = "izac-key"
  public_key = file(pathexpand("~/.ssh/id_ed25519.pub"))
}

resource "aws_security_group" "ssh_access" {
  name        = "allow_ssh"
  description = "Allow SSH access"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
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

resource "aws_security_group" "web" {
  name        = "allow_web"
  description = "Allow HTTP and HTTPS"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
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

resource "aws_instance" "apps" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = "t3.micro"
  key_name             = aws_key_pair.izac_key.key_name
  iam_instance_profile = aws_iam_instance_profile.app_server_profile.name

  vpc_security_group_ids = [
    aws_security_group.ssh_access.id,
    aws_security_group.web.id,
  ]

  user_data = <<-EOF
    #!/bin/bash
    aws secretsmanager get-secret-value \
      --secret-id github-deploy-key \
      --region us-east-1 \
      --query SecretString \
      --output text > /home/ec2-user/.ssh/id_ed25519
    chmod 600 /home/ec2-user/.ssh/id_ed25519
    chown ec2-user:ec2-user /home/ec2-user/.ssh/id_ed25519
  EOF

  tags = {
    Name = "izac-apps"
  }
}

resource "aws_instance" "main" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = "t3.small"
  key_name             = aws_key_pair.izac_key.key_name
  iam_instance_profile = aws_iam_instance_profile.app_server_profile.name

  vpc_security_group_ids = [
    aws_security_group.ssh_access.id,
  ]

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y git
    aws secretsmanager get-secret-value \
      --secret-id github-deploy-key \
      --region us-east-1 \
      --query SecretString \
      --output text > /home/ec2-user/.ssh/id_ed25519
    chmod 600 /home/ec2-user/.ssh/id_ed25519
    chown ec2-user:ec2-user /home/ec2-user/.ssh/id_ed25519
    ssh-keyscan github.com >> /home/ec2-user/.ssh/known_hosts
    chown ec2-user:ec2-user /home/ec2-user/.ssh/known_hosts
    sudo -u ec2-user git clone git@github.com:izacpeterson/js_anon_kv.git /home/ec2-user/js_anon_kv
  EOF

  tags = {
    Name = "izac-main"
  }
}

output "ssh_commands" {
  value = {
    apps = "ssh ec2-user@${aws_instance.apps.public_ip}"
    main = "ssh ec2-user@${aws_instance.main.public_ip}"
  }
}
