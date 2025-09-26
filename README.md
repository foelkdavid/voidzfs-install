# voidzfs-install
Interactive Voidlinux on ZFS installer (optional with zfs-mirror)


## Howto:
1. Download the latest hrmpf image.
2. run this script.

## Features:
- Boots from ZFSBootMenu
- Optional Encryption
- Optional ZFS-Mirror
- Optional Swap
- Creates additional Dataset for /home
- Provides Hooks to keep EFI partitions in-sync on updates.
- Provides Config file for automatic Snapshotting

**This requires UEFI to boot.**

# Filesystem diagram of a mirrored install:
<img width="50%" height="50%" alt="ZFS-Layout" src="https://github.com/user-attachments/assets/55bc44b7-1cc6-4ae2-bff5-a7836250e65a" />
