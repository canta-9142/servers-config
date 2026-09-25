{ lib, pkgs, ... }:
let
  mdadmLog = pkgs.writeShellScript "mdadm-log-event" ''
    echo "mdadm: $*" >&2
  '';
  esp = label: {
    device = "/dev/disk/by-label/${label}";
    fsType = "vfat";
    # A missing ESP must not send stage 2 into emergency mode.
    options = [
      "umask=0077"
      "nofail"
      "x-systemd.device-timeout=10s"
    ];
  };
in
{
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;

    swraid = {
      enable = true;
      # Match only our array UUID on the intended partitions. mdadm's
      # last-resort timer starts an incomplete array after 30s, without force.
      mdadmConf = ''
        DEVICE /dev/disk/by-partlabel/RYZEN_RAID_A /dev/disk/by-partlabel/RYZEN_RAID_B
        HOMEHOST ryzen
        AUTO -all
        ARRAY /dev/md/ryzen metadata=1.2 UUID=841f6aa1:604f4db7:a1548902:1d48109f
        PROGRAM ${mdadmLog}
      '';
    };
    initrd.systemd = {
      enable = true;
      storePaths = [ mdadmLog ];
    };

    loader = {
      efi.canTouchEfiVariables = false;
      grub = {
        enable = true;
        efiSupport = true;
        efiInstallAsRemovable = true;
        copyKernels = true;
        configurationLimit = 10;
        # Each ESP contains its own GRUB, kernel and initrd. No primary-SSD
        # dependency, and the firmware can use EFI/BOOT/BOOTX64.EFI on either.
        mirroredBoots = [
          {
            path = "/boot";
            devices = [ "nodev" ];
          }
          {
            path = "/boot-mirror";
            devices = [ "nodev" ];
          }
        ];
      };
    };
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/RYZEN_ROOT";
      fsType = "ext4";
      options = [ "noatime" ];
    };
    "/boot" = esp "RYZEN_EFI_A";
    "/boot-mirror" = esp "RYZEN_EFI_B";
  };
  swapDevices = [ ];
  # No disk swap; useful until the RAM upgrade.
  zramSwap.enable = lib.mkDefault true;
}
