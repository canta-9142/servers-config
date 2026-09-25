{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "ryzen-raid-boot";

  nodes = {
    installer = { nodes, ... }: {
      nix.enable = true;
      # Match the official installation image, including MD udev rules.
      boot.swraid = {
        enable = true;
        mdadmConf = "PROGRAM ${pkgs.coreutils}/bin/true";
      };
      virtualisation = {
        memorySize = 2048;
        qemu.drives = [
          {
            file = "$NIX_BUILD_TOP/raid-a.qcow2";
            deviceExtraOpts.serial = "raid-a";
          }
          {
            file = "$NIX_BUILD_TOP/raid-b.qcow2";
            deviceExtraOpts.serial = "raid-b";
          }
        ];
      };
      environment.systemPackages = with pkgs; [
        parted
        mdadm
        e2fsprogs
        dosfstools
      ];
      system.extraDependencies = [ nodes.target.system.build.toplevel ];
    };

    target = { lib, ... }: {
      imports = [
        ../hosts/ryzen/storage.nix
        ../modules/system/maintenance.nix
        ../modules/system/ssh.nix
        ../modules/system/common.nix
      ];
      nix.enable = true;
      system.stateVersion = "26.05";
      # The test framework disables this by default; nixos-install needs it.
      system.switch.enable = true;
      boot.loader.grub.extraConfig = "serial; terminal_output serial";
      virtualisation = {
        memorySize = 2048;
        diskImage = null;
        useBootLoader = true;
        useEFIBoot = true;
        useDefaultFilesystems = false;
        fileSystems = lib.mkForce { };
        efi.keepVariables = false;
        qemu.drives = lib.mkForce [
          { file = "$NIX_BUILD_TOP/boot-a.qcow2"; }
          { file = "$NIX_BUILD_TOP/boot-b.qcow2"; }
        ];
      };
    };
  };

  testScript = { nodes, ... }: ''
    import os
    import subprocess

    work = os.environ["NIX_BUILD_TOP"]
    qemu_img = "${pkgs.qemu_test}/bin/qemu-img"

    def new_disk(name):
        subprocess.run([qemu_img, "create", "-f", "qcow2", f"{work}/{name}.qcow2", "12G"], check=True)

    for name in ("raid-a", "raid-b"):
        new_disk(name)
    installer.start()
    installer.wait_for_unit("multi-user.target")
    for disk, suffix in (("disk/by-id/virtio-raid-a", "A"), ("disk/by-id/virtio-raid-b", "B")):
        installer.succeed(
            f"parted -s /dev/{disk} mklabel gpt "
            f"mkpart RYZEN_EFI_{suffix} fat32 1MiB 2049MiB set 1 esp on "
            f"mkpart RYZEN_RAID_{suffix} ext4 2049MiB 100% set 2 raid on"
        )
    installer.succeed("udevadm settle")
    installer.succeed("mkfs.vfat -F32 -n RYZEN_EFI_A /dev/disk/by-partlabel/RYZEN_EFI_A")
    installer.succeed("mkfs.vfat -F32 -n RYZEN_EFI_B /dev/disk/by-partlabel/RYZEN_EFI_B")
    installer.succeed("mdadm --create /dev/md/ryzen --metadata=1.2 --level=1 --raid-devices=2 --bitmap=internal --homehost=ryzen --name=root --uuid=841f6aa1:604f4db7:a1548902:1d48109f /dev/disk/by-partlabel/RYZEN_RAID_A /dev/disk/by-partlabel/RYZEN_RAID_B")
    installer.succeed("mkfs.ext4 -L RYZEN_ROOT /dev/md/ryzen")
    installer.succeed("udevadm settle; mkdir -p /mnt; mount /dev/disk/by-label/RYZEN_ROOT /mnt")
    installer.succeed("mkdir -p /mnt/{nix,srv,boot,boot-mirror}")
    installer.succeed("mount /dev/disk/by-label/RYZEN_EFI_A /mnt/boot; mount /dev/disk/by-label/RYZEN_EFI_B /mnt/boot-mirror")
    installer.succeed("nixos-install --root /mnt --system ${nodes.target.system.build.toplevel} --no-root-passwd --no-channel-copy", timeout=900)
    installer.succeed("test -s /mnt/boot/EFI/BOOT/BOOTX64.EFI && test -s /mnt/boot-mirror/EFI/BOOT/BOOTX64.EFI")
    idle = 'test "$(cat /sys/class/block/$(basename $(readlink -f /dev/md/ryzen))/md/sync_action)" = idle'
    installer.wait_until_succeeds(idle, timeout=300)
    installer.succeed("mdadm --detail --test /dev/md/ryzen")
    installer.shutdown()

    # Each scenario gets fresh overlays of the same healthy pair. Never
    # reconnect two independently modified degraded members.
    for missing in (None, "a", "b"):
        with subtest(f"UEFI boot with missing member: {missing}"):
            for side in ("a", "b"):
                dest = f"{work}/boot-{side}.qcow2"
                if os.path.exists(dest):
                    os.unlink(dest)
                if side == missing:
                    new_disk(f"boot-{side}")
                else:
                    subprocess.run([qemu_img, "create", "-f", "qcow2", "-F", "qcow2", "-b", f"{work}/raid-{side}.qcow2", dest], check=True)
            target.start()
            target.wait_for_unit("multi-user.target", timeout=180)
            target.wait_for_unit("sshd.service")
            target.succeed("findmnt -no FSTYPE / | grep -x ext4; test -d /nix/store")
            target.succeed("echo survived-degraded-write > /srv/raid-write-test; sync")
            if missing is None:
                target.succeed("systemctl start ryzen-storage-health.service")
                target.succeed("mountpoint /boot && mountpoint /boot-mirror")
                target.wait_for_unit("mdmonitor.service")
                target.succeed("systemctl start ryzen-raid-check.service", timeout=300)
                target.succeed("journalctl -u ryzen-raid-check.service | grep 'mismatch_cnt=0'")
            else:
                target.fail("systemctl start ryzen-storage-health.service")
                target.succeed("journalctl -u ryzen-storage-health.service | grep 'ERROR: MD RAID is degraded'")
                target.wait_until_succeeds("journalctl -b -u mdmonitor.service | grep 'mdadm: DegradedArray'", timeout=90)
            target.shutdown()

        if missing is not None:
            with subtest(f"Rejoin stale member {missing} and preserve degraded writes"):
                # Keep the survivor's writes and return only the original stale member.
                dest = f"{work}/boot-{missing}.qcow2"
                os.unlink(dest)
                subprocess.run([qemu_img, "create", "-f", "qcow2", "-F", "qcow2", "-b", f"{work}/raid-{missing}.qcow2", dest], check=True)
                target.start()
                target.wait_for_unit("multi-user.target", timeout=180)
                member = f"/dev/disk/by-partlabel/RYZEN_RAID_{missing.upper()}"
                attached = f'test -e /sys/class/block/$(basename $(readlink -f /dev/md/ryzen))/slaves/$(basename $(readlink -f {member}))'
                if target.execute(attached)[0] != 0:
                    target.succeed(f"mdadm --manage /dev/md/ryzen --re-add {member}")
                target.wait_until_succeeds("mdadm --detail --test /dev/md/ryzen && " + idle, timeout=300)
                target.succeed("systemctl start ryzen-storage-health.service")
                target.succeed("grep -x survived-degraded-write /srv/raid-write-test")
                target.shutdown()
                target.start()
                target.wait_for_unit("multi-user.target", timeout=180)
                target.wait_for_unit("sshd.service")
                target.succeed("systemctl start ryzen-storage-health.service")
                target.succeed("grep -x survived-degraded-write /srv/raid-write-test")
                target.shutdown()
  '';
}
