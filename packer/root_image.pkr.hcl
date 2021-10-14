# This creates a Debian 11 image for EC2 and VMware which is suitable for further provisioning.

packer {
  required_version = "~> 1.7.3"

  required_plugins {
    amazon = {
      version = "=1.0.2-dev"
      source  = "github.com/AlexSc/amazon"
    }
  }
}

variable "region" {
  type        = string
  description = "AWS region to build AMIs in"
}

variable "environment" {
  type        = string
  description = "Value to be assigned to the Environment tag on created AMIs"
}

variable "cost_center" {
  type        = string
  default     = "packer"
  description = "Value to be assigned to the CostCenter tag on all temporary resources and created AMIs"
}

variable "instance_type" {
  type = map(string)
  default = {
    x86_64 = "m5.large"
    arm64  = "m6g.large"
  }
  description = "Instance type to use for building AMIs by architecture"
}

variable "ami_prefix" {
  type        = string
  default     = "packer-root-image"
  description = "Prefix for uniquely generated AMI names"
}

variable "source_ami_owners" {
  type        = list(string)
  description = "A list of AWS account ids which may own AMIs that we use to run the root image builds."
  default     = ["136693071363"]
}

variable "source_ami_name_prefix" {
  type        = string
  description = "The AMI name prefix for AMIs that we use to run the root image builds."
  default     = "debian-11-"
}

variable "vagrant_cloud_version" {
  type        = string
  description = "The version of the published vagrant box. Anything after a '-' will be removed in production."
  default     = "0.0.2-${env("CIRCLE_WORKFLOW_ID")}"
}

data "amazon-parameterstore" "role_arn" {
  region = var.region

  name = "/teak/${var.environment}/ci-cd/packer_role_arn"
}

data "amazon-parameterstore" "instance_profile" {
  region = var.region

  name = "/teak/${var.environment}/ci-cd/instance_profile"
}

data "amazon-parameterstore" "local_vm_bucket" {
  region = var.region

  name = "/teak/${var.environment}/ci-cd/vm_bucket_id"
}

data "amazon-parameterstore" "ami_users" {
  region = var.region

  name = "/teak/${var.environment}/ci-cd/ami_consumers"
}

# Pull the latest Debian 11 AMI
# Packer-ified from https://wiki.debian.org/Cloud/AmazonEC2Image/Bullseye
data "amazon-ami" "base_x86_64_debian_ami" {
  filters = {
    virtualization-type = "hvm"
    name                = "${var.source_ami_name_prefix}*"
    architecture        = "x86_64"
  }
  region      = var.region
  owners      = var.source_ami_owners
  most_recent = true
}

data "amazon-ami" "base_arm64_debian_ami" {
  filters = {
    virtualization-type = "hvm"
    name                = "${var.source_ami_name_prefix}*"
    architecture        = "arm64"
  }
  region      = var.region
  owners      = var.source_ami_owners
  most_recent = true
}

locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
  source_ami = {
    x86_64 = data.amazon-ami.base_x86_64_debian_ami.id
    arm64  = data.amazon-ami.base_arm64_debian_ami.id
  }
  arch_map = { x86_64 = "amd64", arm64 = "arm64" }
  # Make this just be arch_map once Vagrant supports arm.
  vagrant_arch_map = { x86_64 = "amd64" }
  vagrant_cloud_version = var.environment == "production" ? element(split("-", var.vagrant_cloud_version), 0) : var.vagrant_cloud_version
}

source "amazon-ebssurrogate" "debian" {
  assume_role {
    role_arn = data.amazon-parameterstore.role_arn.value
  }

  subnet_filter {
    filters = {
      "tag:Application" : "Packer"
      "tag:Service" : "Build"
    }

    random = true
  }

  run_volume_tags = {
    Managed     = "packer"
    Environment = var.environment
    CostCenter  = var.cost_center
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  iam_instance_profile = data.amazon-parameterstore.instance_profile.value

  region        = var.region
  ebs_optimized = true
  ssh_username  = "admin"

  launch_block_device_mappings {
    volume_type = "gp3"
    # This relies on our source AMI providing an ami root device at /dev/xvda
    # We override the defaults with max free iops and max throughput for
    # gp3 volumes in order to minimize the time to copy the built image to
    # our fresh volume.
    device_name = "/dev/xvda"
    volume_size = 8
    iops        = 3000
    throughput  = 300

    omit_from_artifact    = true
    delete_on_termination = true
  }

  launch_block_device_mappings {
    volume_type = "gp3"
    device_name = "/dev/xvdf"
    volume_size = 2
    iops        = 3000
    throughput  = 300

    delete_on_termination = true
  }

  ami_virtualization_type = "hvm"
  ami_users               = split(",", data.amazon-parameterstore.ami_users.value)
  ena_support             = true
  sriov_support           = true

  ami_root_device {
    source_device_name = "/dev/xvdf"
    device_name        = "/dev/xvda"

    volume_type = "gp2"
    volume_size = 2

    delete_on_termination = true
  }

  tags = {
    Application = "None"
    Environment = var.environment
    CostCenter  = var.cost_center
  }
}

# This is for creating VMware images, and so will not actually create an AMIs.
source "amazon-ebs" "debian" {
  # For use with custom fork of packer-plugin-amazon which implements
  # emit_stub_artifact
  skip_create_ami    = true
  emit_stub_artifact = true

  assume_role {
    role_arn = data.amazon-parameterstore.role_arn.value
  }

  subnet_filter {
    filters = {
      "tag:Application" : "Packer"
      "tag:Service" : "Build"
    }

    random = true
  }

  run_volume_tags = {
    Managed     = "packer"
    Environment = var.environment
    CostCenter  = var.cost_center
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  iam_instance_profile = data.amazon-parameterstore.instance_profile.value

  region        = var.region
  ebs_optimized = true
  ssh_username  = "admin"

  launch_block_device_mappings {
    volume_type = "gp3"
    # This relies on our source AMI providing an ami root device at /dev/xvda
    # We override the defaults with max free iops and max throughput for
    # gp3 volumes in order to minimize the time to copy the built image to
    # our fresh volume.
    device_name = "/dev/xvda"
    volume_size = 8
    iops        = 3000
    throughput  = 300

    delete_on_termination = true
  }

  ami_virtualization_type = "hvm"
  ami_users               = split(",", data.amazon-parameterstore.ami_users.value)
  ena_support             = true
  sriov_support           = true

  tags = {
    Application = "None"
    Environment = var.environment
    CostCenter  = var.cost_center
  }
}

build {
  dynamic "source" {
    for_each = local.arch_map
    iterator = arch
    labels   = ["amazon-ebssurrogate.debian"]

    content {
      name             = "debian_${arch.key}"
      ami_name         = "${var.environment}-${var.ami_prefix}-${arch.key}-${local.timestamp}"
      instance_type    = var.instance_type[arch.key]
      ami_architecture = arch.key

      source_ami = local.source_ami[arch.key]
    }
  }

  dynamic "source" {
    for_each = local.arch_map
    iterator = arch
    labels   = ["amazon-ebs.debian"]

    content {
      name             = "debian_${arch.key}"
      ami_name         = "temp-${var.environment}-${var.ami_prefix}-${arch.key}-${local.timestamp}"
      instance_type    = var.instance_type[arch.key]

      source_ami = local.source_ami[arch.key]
    }
  }

  provisioner "ansible" {
    playbook_file = "${path.root}/playbooks/cloud_images.yml"
    extra_arguments = [
      "--extra-vars", "build_environment=${var.environment}"
    ]
  }

  dynamic "provisioner" {
    for_each = local.arch_map
    iterator = arch
    labels   = ["shell"]

    content {
      only = ["amazon-ebssurrogate.debian_${arch.key}"]
      inline = [
        "cd /build/debian-cloud-images",
        "make image_bullseye_ec2_${arch.value}",
        "sudo dd if=image_bullseye_ec2_${arch.value}.raw of=/dev/xvdf bs=1M"
      ]
    }
  }

  dynamic "provisioner" {
    for_each = local.arch_map
    iterator = arch
    labels   = ["shell"]

    content {
      only = ["amazon-ebs.debian_${arch.key}"]
      inline = [
        "cd /build/debian-cloud-images",
        "make vmware_bullseye_vagrant_${arch.value}",
        "gzip vmware_bullseye_vagrant_${arch.value}.vmdk",
        "aws s3 cp vmware_bullseye_vagrant_${arch.value}.vmdk.gz s3://${data.amazon-parameterstore.local_vm_bucket.value}/vmware_bullseye_vagrant_${arch.value}.vmdk.gz"
      ]
    }
  }

  dynamic "provisioner" {
    for_each = local.arch_map
    iterator = arch
    labels   = ["shell-local"]

    content {
      only = ["amazon-ebs.debian_${arch.key}"]
      inline = [
        "aws s3 cp s3://${data.amazon-parameterstore.local_vm_bucket.value}/vmware_bullseye_vagrant_${arch.value}.vmdk.gz ${path.root}/build/vmware_bullseye_vagrant_${arch.value}.vmdk.gz",
        "gunzip ${path.root}/build/vmware_bullseye_vagrant_${arch.value}.vmdk.gz",
        "cp ${path.root}/vm_configs/vagrant.vmx ${path.root}/build/vagrant_${arch.value}.vmx",
        "sed -i -e 's/^scsi0:0.fileName = DISK_IMAGE/scsi0:0.fileName = \"vmware_bullseye_vagrant_${arch.value}.vmdk\"/' ${path.root}/build/vagrant_${arch.value}.vmx"
      ]
    }
  }

  dynamic "post-processors" {
    for_each = local.vagrant_arch_map
    iterator = arch

    content {
      post-processor "artifice" {
        only  = ["amazon-ebs.debian_${arch.key}"]
        files = ["${path.root}/build/vmware_bullseye_vagrant_${arch.value}.vmdk"]

        keep_input_artifact = false
      }

      post-processor "vagrant" {
        only = ["amazon-ebs.debian_${arch.key}"]

        include = ["${path.root}/build/vagrant_${arch.value}.vmx"]
        output  = "${path.root}/build/debian-11_${arch.value}.box"

        provider_override = "vmware"
      }

      post-processor "vagrant-cloud" {
        only = ["amazon-ebs.debian_${arch.key}"]

        box_tag = "teak/bullseye64"
        version = local.vagrant_cloud_version

        no_release = var.environment != "production"
      }
    }
  }
}
