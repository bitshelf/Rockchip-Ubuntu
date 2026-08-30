# Configuration

This directory contains branch-owned, machine-readable product policy.

- `release.conf` selects the single Ubuntu release owned by this branch.
- `images.conf` defines the supported image matrix.
- `feature-policy.conf` records only policies implemented by migrated feature
  commits. Add entries together with the owning implementation and QA.

Generated configuration and secrets do not belong here.
