variable "aws_region" {
  type    = string
  default = "eu-west-2"
}
variable "vpc_id" {
  type    = string
  default = "vpc-0e108fe4a8ffe3dee"
}
variable "subnet_id" {
  type    = string
  default = "subnet-0bb1a97785b8ba5a5"
}
variable "jenkins_security_group_id" {
  type    = string
  default = "sg-0243f521e59c4d971"
}
variable "home_jenkins_ipv4" {
  type        = string
  description = "Public IPv4 of home Jenkins; SSH only, never MongoDB"
  validation {
    condition     = can(cidrnetmask("${var.home_jenkins_ipv4}/32"))
    error_message = "Supply one IPv4 address, without /32."
  }
}
variable "ssh_public_key_path" {
  type    = string
  default = "/var/lib/jenkins/.ssh/mongodb-lab.pub"
}
variable "instance_type" {
  type    = string
  default = "t3.medium"
}
variable "root_volume_gb" {
  type    = number
  default = 40
  validation {
    condition     = var.root_volume_gb >= 20 && floor(var.root_volume_gb) == var.root_volume_gb
    error_message = "Use at least 20 GiB, in whole GiB."
  }
}

variable "rocky_ami_id" {
  type        = string
  description = "Explicit official Rocky Linux 9 Base x86_64 AMI ID in aws_region. Changing it replaces all three nodes and deletes their root/data disks."
  validation {
    condition     = can(regex("^ami-[0-9a-f]{8}([0-9a-f]{9})?$", var.rocky_ami_id))
    error_message = "Set rocky_ami_id to an official Rocky 9 Base x86_64 AMI in this region."
  }
}
