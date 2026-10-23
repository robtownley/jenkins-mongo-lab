locals {
  nodes = toset(["mongo1", "mongo2", "mongo3"])
}
data "aws_subnet" "lab" { id = var.subnet_id }
data "aws_security_group" "jenkins" { id = var.jenkins_security_group_id }
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
resource "aws_key_pair" "lab" {
  key_name   = "jenkins-mongodb-lab"
  public_key = file(var.ssh_public_key_path)
}
resource "aws_security_group" "database" {
  name        = "jenkins-mongodb-lab"
  description = "MongoDB lab; database port private to members and AWS Jenkins"
  vpc_id      = var.vpc_id
  ingress {
    description = "SSH from home Jenkins"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.home_jenkins_ipv4}/32"]
  }
  ingress {
    description     = "SSH from AWS Jenkins"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.jenkins_security_group_id]
  }
  ingress {
    description = "Replica set traffic"
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    self        = true
  }
  ingress {
    description     = "Private clients on AWS Jenkins security group"
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [var.jenkins_security_group_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_instance" "node" {
  for_each                    = local.nodes
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  key_name                    = aws_key_pair.lab.key_name
  vpc_security_group_ids      = [aws_security_group.database.id]
  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "mongodb-${each.key}-root" }
  }
  metadata_options { http_tokens = "required" }
  credit_specification { cpu_credits = "standard" }
  tags = { Name = "mongodb-${each.key}", Role = each.key }
  lifecycle {
    ignore_changes = [ami]
    precondition {
      condition     = data.aws_subnet.lab.vpc_id == var.vpc_id && data.aws_security_group.jenkins.vpc_id == var.vpc_id
      error_message = "Subnet and Jenkins security group must belong to the chosen VPC."
    }
  }
}
output "nodes" {
  value = { for name, node in aws_instance.node : name => {
    private_ip  = node.private_ip
    public_ip   = node.public_ip
    instance_id = node.id
    hostname    = "${name}.mongodb.lab.internal"
  } }
}
