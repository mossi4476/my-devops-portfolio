data "aws_route53_zone" "selected" {
  count = local.use_https ? 1 : 0

  name         = var.service_domain
  private_zone = false
}

resource "aws_acm_certificate" "acm" {
  count = local.use_https ? 1 : 0

  domain_name       = "*.${var.service_domain}"
  validation_method = "DNS"

  tags = { Name = var.service_domain }
}

resource "aws_route53_record" "r53_record" {
  for_each = local.use_https ? {
    for dvo in aws_acm_certificate.acm[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true

  name    = each.value.name
  records = [each.value.record]
  ttl     = 60
  type    = each.value.type
  zone_id = data.aws_route53_zone.selected[0].zone_id
}

resource "time_sleep" "wait_60_seconds" {
  count = local.use_https ? 1 : 0

  depends_on = [
    aws_acm_certificate.acm,
    aws_route53_record.r53_record
  ]
  create_duration = "60s"
}
