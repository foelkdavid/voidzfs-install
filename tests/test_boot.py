"""Non-destructive installer regression tests; all disk/chroot commands are mocked."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]

MOCKS = r'''
ok() { :; }
info() { :; }
log() { printf '%s\n' "$*" >> "$TEST_LOG"; }
sgdisk() { log "sgdisk $*"; }
partprobe() { log "partprobe $*"; }
mkfs.ext2() { log "mkfs.ext2 $*"; }
blkid() { printf 'uuid-%s\n' "${!#}"; }
tail_window() { shift; "$@"; }
xchroot() {
  local target="$1"; shift
  log "xchroot $*"
  case "$1" in
    mount) touch "$target$2/.mounted" ;;
    mountpoint) [[ -f "$target$3/.mounted" ]] ;;
    xbps-install) : ;;
    generate-zbm)
      if [[ "$VOID_BOOT_MODE" == uefi ]]; then
        mkdir -p "$target/boot/efi/EFI/zbm"
        printf efi-bundle > "$target/boot/efi/EFI/zbm/vmlinuz.EFI"
      else
        mkdir -p "$target/boot/syslinux/zfsbootmenu"
        printf kernel > "$target/boot/syslinux/zfsbootmenu/vmlinuz-bootmenu"
        printf initramfs > "$target/boot/syslinux/zfsbootmenu/initramfs-bootmenu.img"
      fi
      ;;
    sh)
      case "$3" in
        'cp '*) touch "$target$5/menu.c32" "$target$5/ldlinux.c32" ;;
        'cat '*) cat > "$target$5/syslinux.cfg" ;;
        *) return 99 ;;
      esac ;;
    extlinux) printf '%s' "$3" > "$target$3/ldlinux.sys" ;;
    dd) [[ "${FAIL_DD:-false}" != true ]] ;;
    mkdir) mkdir -p "$target$3" ;;
    rsync) command rsync "$2" "$3" "$target$4" "$target$5" ;;
    *) return 99 ;;
  esac
}
'''


class BootTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="voidzfs-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / "target"
        for directory in ("etc/zfsbootmenu", "etc/sv", "usr/local/bin"):
            (self.target / directory).mkdir(parents=True, exist_ok=True)
        self.log = self.root / "commands.log"
        # Redirect hardcoded target paths into the fixture. Disk commands remain
        # mocked, and tests never need root or access to actual block devices.
        self.installer = self.root / "install.sh"
        self.installer.write_text(
            (REPO / "install.sh").read_text().replace("/mnt", str(self.target))
        )

    def bash(self, code, success=True, service=False):
        source = REPO / "services/efisync/efisync.sh" if service else self.installer
        result = subprocess.run(
            ["bash", "-c", 'source "$TEST_SOURCE"\n' + MOCKS + code],
            cwd=REPO,
            env=dict(os.environ, TEST_SOURCE=str(source), TEST_LOG=str(self.log)),
            capture_output=True,
            text=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def commands(self):
        return self.log.read_text()

    def test_detection_and_architecture(self):
        self.bash(r'''
# Use the real detection body with a fixture firmware path.
eval "$(declare -f detect_boot_mode | sed "s|/sys/firmware/efi|$TEST_SOURCE.efi|g")"
mkdir "$TEST_SOURCE.efi"
detect_boot_mode
[[ "$VOID_BOOT_MODE" == uefi ]]
rmdir "$TEST_SOURCE.efi"
detect_boot_mode
[[ "$VOID_BOOT_MODE" == bios ]]
uname() { echo x86_64; }
bootmodecheck
uname() { echo aarch64; }
if bootmodecheck; then exit 1; fi
VOID_BOOT_MODE=uefi
bootmodecheck
''')

    def test_partition_layouts_and_device_names(self):
        for mode in ("bios", "uefi"):
            for mirror in ("false", "true"):
                with self.subTest(mode=mode, mirror=mirror):
                    self.log.write_text("")
                    self.bash(f'''
VOID_BOOT_MODE={mode}
VOID_MIRROR={mirror}
VOID_DISK1=/dev/sda
VOID_DISK2=/dev/nvme0n1
VOID_SWAPSIZE=4
partition_disks
set_zfs_vars
[[ "$BOOT_DEVICE_1" == /dev/sda1 && "$POOL_DEVICE_1" == /dev/sda3 ]]
[[ "$BOOT_DEVICE_2" == /dev/nvme0n1p1 && "$POOL_DEVICE_2" == /dev/nvme0n1p3 ]]
[[ "$(devpart /dev/mmcblk0 2)" == /dev/mmcblk0p2 ]]
''')
                    calls = self.commands()
                    disks = ["/dev/sda", "/dev/nvme0n1"] if mirror == "true" else ["/dev/sda"]
                    for disk in disks:
                        if mode == "bios":
                            self.assertIn(f"sgdisk -n1:1MiB:+512MiB -t1:8300 -c1:BIOSBOOT --attributes=1:set:2 {disk}", calls)
                        else:
                            self.assertIn(f"sgdisk -n1:1MiB:+512MiB -t1:ef00 -c1:EFI {disk}", calls)
                            self.assertNotIn("--attributes", calls)
                        self.assertIn(f"sgdisk -n2:0:+4GiB -t2:8200 -c2:swap {disk}", calls)
                        self.assertIn(f"sgdisk -n3:0:-10MiB -t3:bf00 -c3:zfs {disk}", calls)
                    self.assertEqual(calls.count("sgdisk --zap-all"), len(disks))

    def test_bios_install_single_and_mirror(self):
        for mirror in ("false", "true"):
            with self.subTest(mirror=mirror):
                self.log.write_text("")
                self.bash(f'''
VOID_BOOT_MODE=bios
VOID_MIRROR={mirror}
VOID_DISK1=/dev/sda
VOID_DISK2=/dev/nvme0n1
set_zfs_vars
configure_boot_partitions
setup_zfsbootmenu
if [[ "$VOID_MIRROR" == true ]]; then
  sync_boot_images
  install_efisync
fi
''')
                calls = self.commands()
                primary = self.target / "boot/syslinux"
                self.assertEqual((primary / "ldlinux.sys").read_text(), "/boot/syslinux")
                self.assertIn("xchroot extlinux --install /boot/syslinux", calls)
                self.assertIn("dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/gptmbr.bin of=/dev/sda", calls)
                self.assertNotIn("efibootmgr", calls)
                self.assertNotIn("efivarfs", calls)
                self.assertNotIn("systemd-boot-efistub", calls)
                yaml = (self.target / "etc/zfsbootmenu/config.yaml").read_text()
                self.assertIn("BootMountPoint: /boot/syslinux", yaml)
                self.assertIn("Versions: false\n  Enabled: true", yaml)
                self.assertIn("EFI:\n  Enabled: false", yaml)
                self.assertNotIn("/boot/efi", yaml)
                menu = (primary / "syslinux.cfg").read_text()
                self.assertIn("KERNEL /zfsbootmenu/vmlinuz-bootmenu", menu)
                self.assertIn("INITRD /zfsbootmenu/initramfs-bootmenu-backup.img", menu)
                self.assertIn("APPEND zfsbootmenu quiet loglevel=0", menu)
                fstab = (self.target / "etc/fstab").read_text()
                self.assertIn("/boot/syslinux ext2 defaults", fstab)
                if mirror == "true":
                    secondary = self.target / "boot/syslinux2"
                    self.assertEqual((secondary / "ldlinux.sys").read_text(), "/boot/syslinux2")
                    self.assertEqual((secondary / "syslinux.cfg").read_text(), menu)
                    self.assertEqual((secondary / "zfsbootmenu/vmlinuz-bootmenu").read_text(), "kernel")
                    self.assertIn("/boot/syslinux2 ext2 defaults,nofail", fstab)
                    self.assertIn("xchroot extlinux --install /boot/syslinux2", calls)
                    self.assertIn("of=/dev/nvme0n1", calls)
                    self.bash('source "$TEST_SOURCE"\neval "$(write_bios_sync_config)"\n'
                              'bash -c \'[[ "$SRC" == /boot/syslinux/zfsbootmenu && "$DST_MOUNT" == /boot/syslinux2 ]]\'')
                else:
                    self.assertNotIn("extlinux --install /boot/syslinux2", calls)

    def test_uefi_configuration_and_dispatch_unchanged(self):
        result = self.bash(r'''
VOID_BOOT_MODE=uefi
boot_packages
write_zbm_config
configure_efi_partitions() { echo EFI_CONFIGURATION; }
sync_esps() { echo ESP_SYNC; }
configure_boot_partitions
sync_boot_images
''')
        self.assertIn("systemd-boot-efistub", result.stdout)
        self.assertNotIn("\nsyslinux\n", result.stdout)
        self.assertIn("BootMountPoint: /boot/efi", result.stdout)
        self.assertIn("Versions: 3\n  Enabled: false", result.stdout)
        self.assertIn("Version: false\n  Enabled: true", result.stdout)
        self.assertIn("EFI_CONFIGURATION\nESP_SYNC", result.stdout)

    def test_uefi_generation_fallback_and_mirror_sync(self):
        self.bash(r'''
VOID_BOOT_MODE=uefi
VOID_MIRROR=false
setup_zfsbootmenu
VOID_MIRROR=true
BOOT_DEVICE_2=/dev/sdb1
mkdir -p "$(dirname "$TEST_SOURCE")/target/boot/efi2"
sync_boot_images
install_efisync
''')
        calls = self.commands()
        self.assertIn("xbps-install -S zfsbootmenu systemd-boot-efistub mdadm rsync -y", calls)
        self.assertNotIn("extlinux", calls)
        self.assertNotIn("gptmbr.bin", calls)
        for mount in ("efi", "efi2"):
            fallback = self.target / "boot" / mount / "EFI/BOOT/BOOTX64.EFI"
            self.assertEqual(fallback.read_text(), "efi-bundle")
        self.assertEqual(
            (self.target / "etc/sv/efisync/conf").read_text(),
            (REPO / "services/efisync/efisync/conf").read_text(),
        )

    def test_loader_failure_stops_before_writing_mbr(self):
        self.bash(r'''
xchroot() { log "$*"; return 1; }
install_bios_loader /dev/sda /boot/syslinux
''', success=False)
        self.assertNotIn("extlinux", self.commands())
        self.assertNotIn("dd ", self.commands())

    def test_mbr_failure_is_not_reported_as_success(self):
        result = self.bash(r'''
xchroot() {
  log "$*"
  if [[ "$2" == sh && "$4" == 'cat '* ]]; then cat >/dev/null; fi
  [[ "$2" != dd ]]
}
ok() { echo LOADER_SUCCESS; }
install_bios_loader /dev/sda /boot/syslinux
''', success=False)
        self.assertIn("extlinux --install", self.commands())
        self.assertIn("dd bs=440 count=1 conv=notrunc", self.commands())
        self.assertNotIn("LOADER_SUCCESS", result.stdout)

    def test_image_sync_guards_and_preserves_loaders(self):
        src = self.root / "primary"
        dst = self.root / "secondary"
        for mount in (src, dst):
            (mount / "zfsbootmenu").mkdir(parents=True)
            (mount / "ldlinux.sys").write_text(str(mount))
        (src / "zfsbootmenu/vmlinuz-bootmenu").write_text("updated kernel")
        (src / "zfsbootmenu/vmlinuz-bootmenu-backup").write_text("old kernel")
        (dst / "zfsbootmenu/stale").touch()
        code = f'''
SRC_MOUNT={src}
DST_MOUNT={dst}
SRC="$SRC_MOUNT/zfsbootmenu"
DST="$DST_MOUNT/zfsbootmenu"
LOCK={self.root / 'sync.lock'}
mountpoint() {{ [[ "$2" != "${{MISSING:-}}" ]]; }}
do_sync
'''
        for missing in (src, dst):
            self.bash(f'MISSING={missing}\n' + code, success=False, service=True)
            self.assertTrue((dst / "zfsbootmenu/stale").exists())
        self.bash(code, service=True)
        self.assertFalse((dst / "zfsbootmenu/stale").exists())
        self.assertEqual((dst / "zfsbootmenu/vmlinuz-bootmenu").read_text(), "updated kernel")
        self.assertEqual((dst / "zfsbootmenu/vmlinuz-bootmenu-backup").read_text(), "old kernel")
        self.assertEqual((dst / "ldlinux.sys").read_text(), str(dst))


if __name__ == "__main__":
    unittest.main()
