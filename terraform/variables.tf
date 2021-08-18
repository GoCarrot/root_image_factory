variable "region" {
  description = "The AWS region to create resources in"
  type        = string
  default     = "us-east-1"
}

variable "az_count" {
  description = "The number of availability zones to provision in"
  type        = number
  default     = 2
}

variable "vpc_ipv4_cidr_block" {
  description = "The IPv4 CIDR block to assign to our VPC"
  type        = string
  default     = "10.0.0.0/16"
}
