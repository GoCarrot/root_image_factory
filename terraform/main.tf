terraform {
  backend "s3" {
    bucket         = "teak-terraform-state"
    key            = "server_images"
    region         = "us-east-1"
    dynamodb_table = "teak-terraform-locks"
    encrypt        = true
    kms_key_id     = "a285ccc4-035b-4436-834f-7e0b2d5b0f60"
  }

  required_version = ">= 0.15.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.54"
    }
  }
}

locals {
  default_tags = {
    Managed     = "terraform"
    Environment = terraform.workspace
    CostCenter  = "ServerImages"
    Application = "ServerImages"
    Service     = "ServerImages"
  }

  zones = slice(sort(data.aws_availability_zones.azs.names), 0, var.az_count)
  parameter_prefix = "/teak/${terraform.workspace}/ci-cd"
}

provider "aws" {
  region = var.region
  alias  = "admin"

  default_tags {
    tags = local.default_tags
  }
}

data "aws_caller_identity" "admin" {
  provider = aws.admin
}

data "aws_ssm_parameter" "role_arn" {
  provider = aws.admin

  name = "${local.parameter_prefix}/admin_role_arn"
}

data "aws_caller_identity" "current" {}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }

  assume_role {
    role_arn = data.aws_ssm_parameter.role_arn.value
  }
}

data "aws_availability_zones" "azs" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "build" {
  cidr_block                       = var.vpc_ipv4_cidr_block
  assign_generated_ipv6_cidr_block = true

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "Build"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.build.id

  tags = {
    Name = "Build"
  }
}

resource "aws_egress_only_internet_gateway" "gw" {
  vpc_id = aws_vpc.build.id

  tags = {
    Name = "Build"
  }
}

resource "aws_route_table" "build" {
  vpc_id = aws_vpc.build.id

  tags = {
    Name = "Build"
  }
}

resource "aws_route" "public" {
  route_table_id         = aws_route_table.build.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route" "ipv6-public" {
  route_table_id              = aws_route_table.build.id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.gw.id
}

# The general subnet allocations will be:
# Public subnets: 10.0.0.0/18, 2600:1f18:61f1:2e00::/58
# Spare capacity: 10.0.64.0/19, 2600:1f18:61f1:2e40::/58
# Secure/other private subnets: 10.0.96.0/19, 2600:1f18:61f1:2e80::/58
# General purpose private subnets: 10.0.128.0/17, 2600:1f18:61f1:2ec0::/58

module "base_subnets" {
  source = "git@github.com:GoCarrot/terraform-cidr-subnets.git"

  ipv4_base_cidr_block = aws_vpc.build.cidr_block
  ipv6_base_cidr_block = aws_vpc.build.ipv6_cidr_block

  networks = [
    {
      name          = "public"
      ipv4_new_bits = 2
      ipv6_new_bits = 2
    },
    {
      name          = "spare"
      ipv4_new_bits = 3
      ipv6_new_bits = 2
    },
    {
      name          = "other_private"
      ipv4_new_bits = 3
      ipv6_new_bits = 2
    },
    {
      name          = "private",
      ipv4_new_bits = 1
      ipv6_new_bits = 2
    }
  ]
}

module "public_subnets" {
  source = "git@github.com:GoCarrot/terraform-cidr-subnets.git"

  ipv4_base_cidr_block = module.base_subnets.networks_by_name["public"].ipv4_cidr_block
  ipv6_base_cidr_block = module.base_subnets.networks_by_name["public"].ipv6_cidr_block

  networks = [
    for zone in local.zones :
    {
      name          = zone,
      ipv4_new_bits = 2
      ipv6_new_bits = 6
    }
  ]
}

resource "aws_subnet" "public_subnets" {
  for_each = module.public_subnets.networks_by_name

  vpc_id            = aws_vpc.build.id
  availability_zone = each.key
  cidr_block        = each.value.ipv4_cidr_block
  ipv6_cidr_block   = each.value.ipv6_cidr_block

  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true

  tags = {
    Name        = "Build Subnet ${each.key}"
    Type        = "Public"
    Service     = "Build"
    Application = "Packer"
  }
}

resource "aws_route_table_association" "public_subnets" {
  for_each = module.public_subnets.networks_by_name

  subnet_id      = aws_subnet.public_subnets[each.key].id
  route_table_id = aws_route_table.build.id
}

data "aws_iam_policy_document" "packer" {
  statement {
    actions = [
      "ec2:AttachVolume",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CopyImage",
      "ec2:CreateImage",
      "ec2:CreateKeypair",
      "ec2:CreateSecurityGroup",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:DeleteKeyPair",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSnapshot",
      "ec2:DeleteVolume",
      "ec2:DeregisterImage",
      "ec2:DescribeImageAttribute",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeRegions",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSnapshots",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2:DetachVolume",
      "ec2:GetPasswordData",
      "ec2:ModifyImageAttribute",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifySnapshotAttribute",
      "ec2:RegisterImage",
      "ec2:RunInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
      "iam:PassRole",
      "iam:GetInstanceProfile",
      "ec2:AssociateIamInstanceProfile",
      "ec2:ReplaceIamInstanceProfileAssociation"
    ]

    resources = ["*"]
  }
}

data "aws_iam_policy_document" "packer_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.admin.account_id}:root"
      ]
    }
  }
}

resource "aws_iam_policy" "packer" {
  name        = "Packer"
  description = "Minimum permissions for Packer to run"
  policy      = data.aws_iam_policy_document.packer.json
}

resource "aws_iam_role" "packer" {
  name               = "Packer"
  description        = "Use me to run Packer builds"
  assume_role_policy = data.aws_iam_policy_document.packer_assume_role.json
}

resource "aws_iam_role_policy_attachment" "packer_attach" {
  role       = aws_iam_role.packer.name
  policy_arn = aws_iam_policy.packer.arn
}

resource "aws_s3_bucket" "local_vm" {
  bucket_prefix = "local-vm-storage-${data.aws_caller_identity.current.account_id}-"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "DeleteAll"
    enabled = true

    expiration {
      days = 1
    }

    noncurrent_version_expiration {
      days = 1
    }
  }
}

resource "aws_s3_bucket_public_access_block" "local_vm" {
  bucket = aws_s3_bucket.local_vm.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_ssm_parameter" "ami_consumers" {
  provider = aws.admin

  name = "${local.parameter_prefix}/ami_consumers"
}

data "aws_iam_policy_document" "allow_bucket_read" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.local_vm.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [for id in split(",", data.aws_ssm_parameter.ami_consumers.value) : "arn:aws:iam::${id}:root"]
    }
  }
}

resource "aws_s3_bucket_policy" "allow_bucket_read" {
  bucket = aws_s3_bucket.local_vm.id
  policy = data.aws_iam_policy_document.allow_bucket_read.json

  # Bucket policy and public access block cannot be "created" concurrently.
  # By depending on the public access block we serialize application of the policy
  # and public access block.
  depends_on = [
    aws_s3_bucket_public_access_block.local_vm
  ]
}

# Allow Packer builds to upload files to our local_vm bucket
data "aws_iam_policy_document" "allow_vm_upload" {
  statement {
    effect    = "Allow"
    actions   = [
      "s3:PutObject",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      "${aws_s3_bucket.local_vm.arn}/*"
    ]
  }
}

data "aws_iam_policy_document" "allow_ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "allow_vm_upload" {
  name        = "AllowUploadToLocalVM"
  description = "Allows putting objects in the local vm storage bucket"

  policy = data.aws_iam_policy_document.allow_vm_upload.json
}

resource "aws_iam_role" "vm_builder" {
  name        = "VMBuilder"
  description = "Role for EC2 instances building VMs"

  assume_role_policy = data.aws_iam_policy_document.allow_ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "vm_builder_allow" {
  role       = aws_iam_role.vm_builder.name
  policy_arn = aws_iam_policy.allow_vm_upload.arn
}

resource "aws_iam_instance_profile" "vm_builder" {
  name = "VMBuilder"
  role = aws_iam_role.vm_builder.name
}

resource "aws_ssm_parameter" "packer_role" {
  provider = aws.admin

  name = "${local.parameter_prefix}/packer_role_arn"
  type = "String"

  description = "Role to assume to execute packer"

  value = aws_iam_role.packer.arn
}

resource "aws_ssm_parameter" "vmbuilder_role" {
  provider = aws.admin

  name = "${local.parameter_prefix}/instance_profile"
  type = "String"

  description = "Instance profile to assign to image builders in CI/CD"

  value = aws_iam_instance_profile.vm_builder.name
}

resource "aws_ssm_parameter" "vm_bucket" {
  provider = aws.admin

  name = "${local.parameter_prefix}/vm_bucket_id"
  type = "String"

  description = "ID of S3 bucket that local use VM images are uploaded to"

  value = aws_s3_bucket.local_vm.id
}
