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

    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.2"
    }
  }
}

provider "aws" {
  region = var.region
  alias  = "meta_read"
}

module "current_account" {
  source  = "GoCarrot/accountomat_read/aws"
  version = "0.0.3"

  providers = {
    aws = aws.meta_read
  }

  canonical_slug = terraform.workspace
}

locals {
  service = "ServerImages"

  default_tags = {
    Managed     = "terraform"
    Environment = module.current_account.environment
    CostCenter  = local.service
    Application = local.service
    Service     = local.service
  }

  zones            = slice(sort(data.aws_availability_zones.azs.names), 0, var.az_count)
  parameter_prefix = module.current_account.param_prefix
}

provider "aws" {
  region = var.region
  alias  = "admin"

  default_tags {
    tags = local.default_tags
  }
}

provider "dns" {}

data "aws_caller_identity" "admin" {
  provider = aws.admin
}

data "aws_ssm_parameter" "role_arn" {
  provider = aws.admin

  name = "${local.parameter_prefix}/roles/admin"
}

data "aws_caller_identity" "current" {}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }

  assume_role {
    role_arn = data.aws_ssm_parameter.role_arn.value
    external_id = var.external_id
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

resource "aws_cloudwatch_log_group" "ancillary" {
  for_each = toset(var.ancillary_log_groups)

  name              = "/${module.current_account.organization_prefix}/server/${module.current_account.environment}/ancillary/${each.key}"
  retention_in_days = var.log_retention_days

  tags = {
    CostCenter = "Ancillary"
  }
}

resource "aws_cloudwatch_log_group" "service" {
  name              = "/${module.current_account.organization_prefix}/server/${module.current_account.environment}/service/unknown"
  retention_in_days = var.log_retention_days

  tags = {
    CostCenter = "unknown"
  }
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

    dynamic "condition" {
      for_each = var.external_id != null ? [1] : []

      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.external_id]
      }
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


data "aws_ssm_parameter" "ami_consumers" {
  provider = aws.admin

  name = "${local.parameter_prefix}/config/${local.service}/ami_consumers"
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

data "aws_iam_policy_document" "log_access" {
  statement {
    sid    = "AllowDescribeCreateLogStreams"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:/${module.current_account.organization_prefix}/server/&{aws:PrincipalTag/Environment}/ancillary/*",
      "arn:aws:logs:*:*:log-group:/${module.current_account.organization_prefix}/server/&{aws:PrincipalTag/Environment}/service/*",
    ]
  }

  statement {
    sid    = "AllowDescribeLogGroups"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:*",
    ]
  }

  statement {
    sid    = "AllowPutLogEvents"
    effect = "Allow"
    actions = [
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:/${module.current_account.organization_prefix}/server/&{aws:PrincipalTag/Environment}/ancillary/*:log-stream:*",
      "arn:aws:logs:*:*:log-group:/${module.current_account.organization_prefix}/server/&{aws:PrincipalTag/Environment}/service/*:log-stream:*",
    ]
  }
}

resource "aws_iam_policy" "log_access" {
  name   = "LogAccess"
  policy = data.aws_iam_policy_document.log_access.json
}

resource "aws_iam_role" "vm_builder" {
  name        = "VMBuilder"
  description = "Role for EC2 instances building VMs"

  assume_role_policy = data.aws_iam_policy_document.allow_ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "log_access" {
  role       = aws_iam_role.vm_builder.name
  policy_arn = aws_iam_policy.log_access.arn
}

resource "aws_iam_instance_profile" "vm_builder" {
  name = "VMBuilder"
  role = aws_iam_role.vm_builder.name
}

resource "aws_ssm_parameter" "packer_role" {
  provider = aws.admin

  name = "${local.parameter_prefix}/roles/packer"
  type = "String"

  description = "Role to assume to execute packer"

  value = aws_iam_role.packer.arn
}

resource "aws_ssm_parameter" "vmbuilder_role" {
  provider = aws.admin

  name = "${local.parameter_prefix}/config/${local.service}/instance_profile"
  type = "String"

  description = "Instance profile to assign to image builders in CI/CD"

  value = aws_iam_instance_profile.vm_builder.name
}

data "dns_a_record_set" "circleci-ips" {
  host = "all.knownips.circleci.com"
}

resource "aws_security_group" "circleci-ssh" {
  name        = "CircleCI-SSHAccess"
  description = "Allows SSH access from known CirlceCI IPs"

  vpc_id = aws_vpc.build.id

  ingress {
    description = "SSH from CircleCI"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = formatlist("%s/32", data.dns_a_record_set.circleci-ips.addrs)
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_ssm_parameter" "security-group" {
  provider = aws.admin

  name = "${local.parameter_prefix}/config/${local.service}/security_group_name"
  type = "String"

  description = "Security group which allows inbound SSH from CI/CD servers."

  value = aws_security_group.circleci-ssh.name
}
