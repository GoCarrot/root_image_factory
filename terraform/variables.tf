# Copyright 2021 Teak.io, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

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

variable "log_retention_days" {
  description = "How long in days to retain logs from builds."
  type        = number
  default     = 1827
}

variable "ancillary_log_groups" {
  description = "A list of services to collect logs from on build machines"
  type        = list(string)
  default     = ["fluentd", "systemd", "cloudinit", "configurator", "newrelic-infra"]
}

variable "external_id" {
  description = "The ExternalId used for assuming roles during deployment."
  type        = string
  default     = null
}
