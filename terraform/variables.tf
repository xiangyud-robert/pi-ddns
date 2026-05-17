variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-west-2"
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID (e.g. Z1D633PJN98FT9)"
  type        = string
}

variable "record_name" {
  description = "Fully-qualified DNS record to upsert (e.g. home.example.com)"
  type        = string
}

variable "ttl" {
  description = "TTL in seconds for the Route53 A record"
  type        = number
  default     = 60
}

# API Gateway throttle / quota
variable "api_throttle_rate_limit" {
  description = "Steady-state requests per second allowed by the usage plan"
  type        = number
  default     = 1
}

variable "api_throttle_burst_limit" {
  description = "Maximum concurrent requests (burst) allowed by the usage plan"
  type        = number
  default     = 1
}

variable "api_quota_limit" {
  description = "Maximum number of requests per day allowed by the usage plan"
  type        = number
  default     = 300
}

variable "tf_state_bucket" {
  description = "S3 bucket name used for Terraform state (used to scope the GitHub Actions IAM policy)"
  type        = string
}

# OIDC / GitHub Actions
variable "github_org" {
  description = "GitHub organisation or user that owns the repo (e.g. myusername)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (e.g. pi-ddns)"
  type        = string
}
