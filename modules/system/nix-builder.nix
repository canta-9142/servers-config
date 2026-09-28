{ config, ... }:
{
  users.groups.nix-builder = { };
  users.users.nix-builder = {
    isSystemUser = true;
    group = "nix-builder";
    useDefaultShell = true;
    openssh.authorizedKeys.keys = [
      ''restrict,command="${config.nix.package}/bin/nix-daemon --stdio" ${builtins.readFile ../../hosts/ryzen/nix-builder.pub}''
    ];
  };
  services.openssh.settings.AllowUsers = [ "nix-builder" ];
  nix.settings = {
    trusted-users = [ "nix-builder" ];
    max-jobs = "auto";
    cores = 15;
    extra-system-features = [ "big-parallel" ];
  };
}
