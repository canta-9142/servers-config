{ pkgs, ... }:
{
  services = {
    smartd = {
      enable = true;
      autodetect = true;
      notifications = {
        mail.enable = false;
        wall.enable = false;
        x11.enable = false;
        systembus-notify.enable = false;
      };
    };
    fstrim.enable = true;
    journald.settings.Journal = {
      Storage = "persistent";
      SystemMaxUse = "512M";
      RuntimeMaxUse = "128M";
      MaxRetentionSec = "30day";
    };
  };

  systemd = {
    services = {
      mdmonitor.wantedBy = [ "multi-user.target" ];
      ryzen-storage-health = {
        description = "Check Ryzen MD RAID health (journal only)";
        after = [ "local-fs.target" ];
        serviceConfig.Type = "oneshot";
        path = with pkgs; [
          mdadm
          coreutils
        ];
        script = builtins.readFile ./storage-health.sh;
      };
      ryzen-raid-check = {
        description = "Check Ryzen RAID consistency without requesting repair";
        after = [ "local-fs.target" ];
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = "infinity";
        };
        path = with pkgs; [
          mdadm
          coreutils
        ];
        script = builtins.readFile ./raid-check.sh;
      };
    };
    timers = {
      ryzen-storage-health = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "5min";
        };
      };
      ryzen-raid-check = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "monthly";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };
    };
  };

  nix.gc = {
    automatic = true;
    dates = "Sun 04:00";
    options = "--delete-older-than 30d";
    persistent = true;
  };
}
