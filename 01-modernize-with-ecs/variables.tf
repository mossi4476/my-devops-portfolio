variable "cluster_name" {
  default = "devops-blueprint"
}

variable "aws_region" {
  default = "us-east-1"
}

variable "aws_profile" {}

variable "environment" {
  default = "dev"
}

variable "application" {
  default = "devops-blueprint-app"
}

# leave empty ("") to run HTTP-only via the ALB DNS name, no Route53 hosted zone / ACM needed
variable "service_domain" {
  default = ""
}

variable "retention_days" {
  default = 90
}
variable "instance_type" {}
variable "tfstate_bucket" {}
variable "tfstate_key" {}
