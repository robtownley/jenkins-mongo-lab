# Records belong to MongoDB state; the existing hosted zone is read-only.
data "aws_route53_zone" "lab" {
  name         = "roblabb.com."
  private_zone = false
}

resource "aws_route53_record" "lab" {
  for_each = aws_instance.node

  zone_id = data.aws_route53_zone.lab.zone_id
  name    = "${each.key}.roblabb.com"
  type    = "A"
  ttl     = 60
  records = [each.value.public_ip]

  # Import existing records instead of taking ownership silently.
  allow_overwrite = false

  lifecycle {
    precondition {
      condition     = each.value.public_ip != ""
      error_message = "Each MongoDB DNS target must have a public IPv4 address."
    }
  }
}

output "lab_dns" {
  description = "Public SSH names; MongoDB replication still uses private member names."
  value = {
    for name, record in aws_route53_record.lab : name => {
      hostname = record.fqdn
      address  = aws_instance.node[name].public_ip
    }
  }
}
