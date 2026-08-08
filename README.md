# Root Image Factory

This uses Packer to create root Debian 11 images.

#### A note on terminology

We use `Root Image` to mean a completely unprovisioned bare image with nothing beyond a basic OS install. We use `Base Image` to mean a partially provisioned image with services required by all operational servers, e.g. monitoring, log aggregation, telemetry, etc.

## Local System Requirements
- packer >= 1.7.3
- ansible >= 4.3

## Building

Change to the `packer` directory and run

`packer build -timestamp-ui root_image.pkr.hcl`

to build root Debian 11 AMIs and Vagrant boxes. See `.circleci/config.yml` for how CI
invokes this per account.
