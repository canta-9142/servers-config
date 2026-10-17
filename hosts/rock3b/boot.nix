_:

{
  boot.loader = {
    grub.enable = false;
    generic-extlinux-compatible.enable = true;
  };

  boot.growPartition = true;
  fileSystems."/".autoResize = true;
}
