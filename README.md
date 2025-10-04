# voidzfs-install
Interactive Voidlinux on ZFS installer (optional with zfs-mirror)

TODO: - Single-Disk setup is not tested aswell, coming soon...
TODO: - Custom services for Snapshotting and EFI-Syncing
TODO: - Test and finish implementation of single-disk setup

## Howto:
1. Download the latest hrmpf image.
2. run this script.

## Features:
- Boots from ZFSBootMenu
- Optional Encryption
- Optional ZFS-Mirror Setup
    - Two EFI-Partitions for true redundance
        - synced once after installation, then synced continuously by custom service (TODO)
    - ZFS-Mirrored System Partitions
- Optional Swap
- Creates additional dataset for /home
- Provides runit services for automatic Snapshotting + continuous EFI-Syncing (TODO

**This requires UEFI to boot.**

# Filesystem diagram of a mirrored install:
<img width="50%" height="50%" alt="ZFS-Layout" src="https://github.com/user-attachments/assets/55bc44b7-1cc6-4ae2-bff5-a7836250e65a" />
