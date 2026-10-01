# zfs-install provides two services to enable after reboot:
1. efisync
    -> Enable this on mirrored installs. For UEFI it synchronizes the EFI
       partitions. For BIOS it synchronizes only the ZFSBootMenu image directory
       between `/boot/syslinux` and `/boot/syslinux2`, keeping loader files local
       to each disk. BIOS synchronization requires both boot filesystems to be
       mounted; it fails and runit retries if a disk is absent.
2. zfs-autosnap -> Autosnaps+Prunes Datasets based on a config file.
    -> Use your own solution or use this one :)
