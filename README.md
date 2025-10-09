# voidzfs-install
Interactive Voidlinux on ZFS installer (optional with zfs-mirror)

<img width="50%" height="50%" alt="image" src="https://github.com/user-attachments/assets/e9036490-1053-4d29-b139-d70d9176a81a" />

Warning! Single-Disk Setup is currently broken!

## Howto:
1. Download the latest hrmpf image.
2. run this script.

## Features:
- Boots from ZFSBootMenu
- Encryptes FS
- Optional ZFS-Mirror Setup
    - Two EFI-Partitions for true redundancy
        - synced once after installation, then synced continuously by custom service
    - ZFS-Mirrored System Partitions
- Customizable Swap-Partition (no swap is currently not supported -> TODO)
- Creates additional dataset for /home
- Provides runit services for automatic Snapshotting + continuous EFI-Syncing

**This requires UEFI to boot.**

# Rough FS diagram:
<img width="40%" height="40%" alt="ZFS-Layout" src="https://github.com/user-attachments/assets/55bc44b7-1cc6-4ae2-bff5-a7836250e65a" />
