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

output "packer_role_arn" {
  description = "ARN of role to assume to run Packer builds"

  value = aws_iam_role.packer.arn
}

output "environment" {
  value = terraform.workspace
}

output "region" {
  value = var.region
}

output "local_vm_bucket" {
  description = "The S3 bucket which local vm images are stored in"
  value       = aws_s3_bucket.local_vm.id
}

output "vm_builder_instance_profile" {
  description = "The instance profile to assign to VM building instances"
  value       = aws_iam_instance_profile.vm_builder.name
}
