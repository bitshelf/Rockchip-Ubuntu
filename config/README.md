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

Cross-build release selection stays in the untracked `.env`; it is not encoded
in product configuration.

SDK binary input selection is declared separately from product/rootfs policy:

- `kernel-modules/modules.conf` selects the small set of SDK KO files;
- `local-debs/packages.conf` selects local SDK Debian packages and their
  expected target architecture.

Independent boot filesystem policy is kept in `bootfs/bootfs.conf`; the
builder consumes verified platform assets and does not encode board filenames.

Repository DTS overlay sources live directly in `dts/`. The bootfs builder
compiles `.dtso` files and installs `.dtbo` files. Every supported file in the
selected directory is enabled; product configuration selects a directory, not
SoC-specific filenames.

The immutable-root contract is split by responsibility:

- `kernel/overlay-root.conf` is a portable kernel config fragment and
  acceptance contract;
- `overlay-root/` owns the initramfs policy, fstab and persistent userdata
  identity. It never formats an unrecognized device during boot.

`adb/` owns the common USB FunctionFS gadget and service policy. adbd stays in
the host network namespace and runs as root so ADB and serial diagnostics see
the same board state.
