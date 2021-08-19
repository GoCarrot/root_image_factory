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
