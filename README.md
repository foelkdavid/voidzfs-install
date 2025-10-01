# voidzfs-install
Interactive Voidlinux on ZFS installer (optional with zfs-mirror)


## Howto:
1. Download the latest hrmpf image.
2. run this script.

## Features:
- Boots from ZFSBootMenu
- Optional Encryption
- Optional Raid1/Mirror Setup
    - RAID1 mirrored EFI-Partitions via mdadm
    - ZFS-Mirrored System Partitions
- Optional Swap
- Creates additional dataset for /home
- Provides runit services for automatic Snapshotting

**This requires UEFI to boot.**

# Filesystem diagram of a mirrored install:
<img width="50%" height="50%" alt="ZFS-Layout" src="https://github.com/user-attachments/assets/55bc44b7-1cc6-4ae2-bff5-a7836250e65a" />
