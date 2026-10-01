# voidzfs-install
Interactive Voidlinux on ZFS installer (optional with zfs-mirror)

<img width="50%" height="50%" alt="image" src="https://github.com/user-attachments/assets/e9036490-1053-4d29-b139-d70d9176a81a" />

## Howto:
1. Download the latest hrmpf image.
2. run this script.

## Features:
- Boots from ZFSBootMenu
- Encryptes FS
- Optional ZFS-Mirror Setup
    - Two boot partitions for true redundancy
        - synced once after installation, then synced continuously by custom service
    - ZFS-Mirrored System Partitions
- Customizable Swap-Partition (no swap is currently not supported -> TODO)
- Creates additional dataset for /home
- Provides runit services for automatic Snapshotting + continuous boot image syncing

The installer automatically detects whether the live environment was booted in
UEFI or legacy BIOS mode and installs the matching bootloader. Boot the live USB
in the same mode you want to use for the installed system; there is no manual
override or combined BIOS/UEFI installation.

UEFI installs use the existing EFI System Partition layout and ZFSBootMenu EFI
image. BIOS installs currently support x86_64 and use Syslinux/Extlinux to load
ZFSBootMenu from a 512 MiB ext2 boot partition on GPT. Partition 2 remains swap
and partition 3 remains encrypted ZFS. `/boot` stays within the ZFS root dataset;
only `/boot/syslinux` (and `/boot/syslinux2` for mirrors) is mounted separately.

On BIOS mirrors, both disks receive their own bootloader, so either disk can
boot independently. The `efisync` service synchronizes only ZFSBootMenu images
and preserves each disk's loader files. Enable `efisync` after rebooting to keep
mirror boot images synchronized, and enable `zfs-autosnap` for automatic snapshots.

# Rough FS diagram:
<img width="40%" height="40%" alt="ZFS-Layout" src="https://github.com/user-attachments/assets/55bc44b7-1cc6-4ae2-bff5-a7836250e65a" />
