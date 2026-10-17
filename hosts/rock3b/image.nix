{ pkgs, config }:
let
  inherit (pkgs) lib;
  loader = config.boot.loader.generic-extlinux-compatible;
  extlinuxBuilder =
    import
      "${pkgs.path}/nixos/modules/system/boot/loader/generic-extlinux-compatible/extlinux-conf-builder.nix"
      {
        inherit pkgs lib;
      };
  bootFiles = pkgs.runCommand "rock3b-image-boot" { } ''
    ${extlinuxBuilder} -c ${config.system.build.toplevel} -d "$out" \
      -g ${toString loader.configurationLimit} \
      -t ${if config.boot.loader.timeout == null then "-1" else toString config.boot.loader.timeout} \
      ${
        lib.optionalString (
          config.hardware.deviceTree.name != null
        ) "-n ${lib.escapeShellArg config.hardware.deviceTree.name}"
      } \
      ${lib.optionalString (!loader.useGenerationDeviceTree) "-r"}
  '';
  rootUUID = lib.removePrefix "/dev/disk/by-uuid/" config.fileSystems."/".device;
in
assert lib.hasPrefix "/dev/disk/by-uuid/" config.fileSystems."/".device;
import "${pkgs.path}/nixos/lib/make-disk-image.nix" {
  inherit pkgs lib;
  # Image assembly runs on x86_64; the installed system remains aarch64.
  config = lib.recursiveUpdate config {
    system.build.nixos-install = pkgs.nixos-install;
  };
  name = "rock3b-nvme-image";
  baseName = "rock3b-nvme";
  format = "raw";
  partitionTableType = "legacy";
  rootFSUID = rootUUID;
  additionalSpace = "5G";
  copyChannel = false;
  # extlinux files are populated above; U-Boot is already installed on the board.
  installBootLoader = false;
  contents = [
    {
      source = bootFiles;
      target = "/boot";
    }
  ];
  postVM = ''
    ${pkgs.parted}/bin/parted --script "$diskImage" set 1 boot on
  '';
}
