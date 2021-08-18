# Root Image Factory

This provisions a CI/CD account in a multiaccount AWS setup and then uses that account to create root Debian 11 images.

#### A note on terminology

We use `Root Image` to mean a completely unprovisioned bare image with nothing beyond a basic OS install. We use `Base Image` to mean a partially provisioned image with services required by all operational servers, e.g. monitoring, log aggregation, telemetry, etc.

## Local System Requirements
- terraform >= 1.0
- packer >= 1.7.3
- ansible >= 4.3

## Provisioning
We use terraform workspaces, and the terraform module is configured such that use of the default workspace is invalid. The development workspace will configure and use our development Infrastructure AWS account, and the production workspace will correspondingly use our production Infrastructure AWS account.

Select a workspace with `terraform workspace select development`

Then run `terraform plan -var-file=<workspace>.tfvars -out=run.tfplan`. Verify the proposed modifications. If they all look good, run `terraform apply run.tfplan` to apply changes.

After running terraform, change to the root_image directory and run

`packer build -timestamp-ui root_image.pkr.hcl`

to build root Debian 11 AMIs and Vagrant boxes.
