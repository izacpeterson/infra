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

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
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
    to_port  = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "apps" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = "t3.micro"
  key_name             = aws_key_pair.izac_key.key_name
  iam_instance_profile = aws_iam_instance_profile.app_server_profile.name

  vpc_security_group_ids = [
    aws_security_group.ssh_access.id,
    aws_security_group.web.id,
  ]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y ca-certificates curl git unzip
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    usermod -aG docker ubuntu
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    ssh-keyscan github.com >> /home/ubuntu/.ssh/known_hosts
    chown ubuntu:ubuntu /home/ubuntu/.ssh/known_hosts
    aws secretsmanager get-secret-value \
      --secret-id github-deploy-key \
      --region us-east-1 \
      --query SecretString \
      --output text | tr -d '\r' > /home/ubuntu/.ssh/id_ed25519
    chmod 600 /home/ubuntu/.ssh/id_ed25519
    chown ubuntu:ubuntu /home/ubuntu/.ssh/id_ed25519
    sudo -u ubuntu git clone git@github.com:izacpeterson/infra.git /home/ubuntu/infra
    sudo -u ubuntu git clone git@github.com:izacpeterson/izacdotcomapi.git /home/ubuntu/izacdotcomapi
    docker compose -f /home/ubuntu/infra/compose/docker-compose.yml up -d --build
  EOF

  tags = {
    Name = "izac-apps"
  }
}

resource "aws_instance" "main" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = "t3.small"
  key_name             = aws_key_pair.izac_key.key_name
  iam_instance_profile = aws_iam_instance_profile.app_server_profile.name

  vpc_security_group_ids = [
    aws_security_group.ssh_access.id,
  ]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y git unzip
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    ssh-keyscan github.com >> /home/ubuntu/.ssh/known_hosts
    chown ubuntu:ubuntu /home/ubuntu/.ssh/known_hosts
    aws secretsmanager get-secret-value \
      --secret-id github-deploy-key \
      --region us-east-1 \
      --query SecretString \
      --output text | tr -d '\r' > /home/ubuntu/.ssh/id_ed25519
    chmod 600 /home/ubuntu/.ssh/id_ed25519
    chown ubuntu:ubuntu /home/ubuntu/.ssh/id_ed25519
    sudo -u ubuntu git clone git@github.com:izacpeterson/js_anon_kv.git /home/ubuntu/js_anon_kv
  EOF

  tags = {
    Name = "izac-main"
  }
}

output "ssh_commands" {
  value = {
    apps = "ssh ubuntu@${aws_instance.apps.public_ip}"
    main = "ssh ubuntu@${aws_instance.main.public_ip}"
  }
}
