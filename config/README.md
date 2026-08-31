# Configuration

This directory contains branch-owned, machine-readable product policy.

- `feature-policy.conf` records only policies implemented by migrated feature
  commits. Add entries together with the owning implementation and QA.

Generated configuration and secrets do not belong here.

The Server rootfs feature currently owns:

- `ubuntu-image/resolute-server-arm64.yaml.in`: the rootfs definition;
- `ubuntu-image/seeds/`: the product seed. It deliberately avoids the Ubuntu
  Server meta-package so product-forbidden packages are never selected.

Board boot policy and later product features must not be added to the Server
definition until their own feature is migrated.
