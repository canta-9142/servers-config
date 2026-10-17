{
  pkgs,
  ...
}:

let
  monitorEdid = pkgs.runCommand "monitor-edid" { } ''
    mkdir -p "$out/lib/firmware/edid"
    cp ${../../assets/edid/monitor-rk3568.bin} "$out/lib/firmware/edid/monitor-rk3568.bin"
  '';
  configureEthernetLeds = pkgs.writeShellApplication {
    name = "rock3b-configure-ethernet-leds";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.phytool
    ];
    text = ''
      iface="$1"
      attempt=1

      while [ "$attempt" -le 30 ]; do
        echo "configuring RTL8211F LEDs on $iface ($attempt/30)"

        if phytool write "$iface/1/31" 0x0d04 &&
           phytool write "$iface/1/16" 0x617f &&
           phytool write "$iface/1/31" 0x0000; then
          echo "configured RTL8211F LEDs on $iface"
          exit 0
        fi

        phytool write "$iface/1/31" 0x0000 || true
        sleep 1
        attempt=$((attempt + 1))
      done

      echo "Failed to configure LEDs on $iface" >&2
      exit 1
    '';
  };
  fanController = pkgs.writeShellApplication {
    name = "rock3b-fan-controller";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      thermal_zone=""
      pwm_path=""

      for _ in {1..30}; do
        for zone in /sys/class/thermal/thermal_zone*; do
          if [[ -e "$zone/type" ]] && [[ "$(< "$zone/type")" == "cpu-thermal" ]]; then
            thermal_zone="$zone"
            break
          fi
        done

        for hwmon in /sys/class/hwmon/hwmon*; do
          if [[ -e "$hwmon/name" ]] && [[ "$(< "$hwmon/name")" == "pwmfan" ]]; then
            pwm_path="$hwmon/pwm1"
            break
          fi
        done

        if [[ -n "$thermal_zone" && -w "$pwm_path" ]]; then
          break
        fi

        sleep 1
      done

      if [[ -z "$thermal_zone" || ! -w "$pwm_path" ]]; then
        echo "CPU thermal zone or PWM fan was not found" >&2
        exit 1
      fi

      full_speed() {
        printf '255\n' > "$pwm_path" || true
      }
      trap full_speed EXIT
      trap 'exit 0' INT TERM HUP

      # Keep the fan at full speed until the first valid temperature reading.
      full_speed

      state=-1
      while true; do
        temperature="$(< "$thermal_zone/temp")"

        if [[ ! "$temperature" =~ ^[0-9]+$ ]]; then
          echo "Invalid CPU temperature: $temperature" >&2
          exit 1
        fi

        case "$state" in
          -1|0)
            if (( temperature >= 70000 )); then
              next_state=3
            elif (( temperature >= 60000 )); then
              next_state=2
            elif (( temperature >= 50000 )); then
              next_state=1
            else
              next_state=0
            fi
            ;;
          1)
            if (( temperature >= 70000 )); then
              next_state=3
            elif (( temperature >= 60000 )); then
              next_state=2
            elif (( temperature < 48000 )); then
              next_state=0
            else
              next_state=1
            fi
            ;;
          2)
            if (( temperature >= 70000 )); then
              next_state=3
            elif (( temperature < 58000 )); then
              next_state=1
            else
              next_state=2
            fi
            ;;
          3)
            if (( temperature < 68000 )); then
              next_state=2
            else
              next_state=3
            fi
            ;;
        esac

        if (( next_state != state )); then
          case "$next_state" in
            0) pwm=0; percent=0 ;;
            1) pwm=115; percent=45 ;;
            2) pwm=179; percent=70 ;;
            3) pwm=255; percent=100 ;;
          esac

          printf '%s\n' "$pwm" > "$pwm_path"
          echo "CPU $((temperature / 1000)) C: fan $percent% (state $next_state)"
          state="$next_state"
        fi

        sleep 2
      done
    '';
  };
in
{
  services.fstrim.enable = true;

  hardware.firmware = [
    monitorEdid
  ];

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelModules = [ "pwm-fan" ];
    initrd = {
      availableKernelModules = [ "nvme" ];
      extraFirmwarePaths = [ "edid/monitor-rk3568.bin" ];
    };
    kernelParams = [
      "console=ttyS2,1500000n8"
      "console=tty0"
      "drm.edid_firmware=HDMI-A-1:edid/monitor-rk3568.bin"
    ];
  };

  # Enslaving an interface to a bond may reset its PHY after the boot-time
  # oneshot has run. Reapply the LED registers whenever a physical port is up.
  networking.networkmanager.dispatcherScripts = [
    {
      source = pkgs.writeShellScript "rock3b-ethernet-leds-dispatcher" ''
        iface="$1"
        action="$2"

        case "$iface:$action" in
          end0:up|end1:up)
            exec ${configureEthernetLeds}/bin/rock3b-configure-ethernet-leds "$iface"
            ;;
        esac
      '';
      type = "basic";
    }
  ];

  hardware.deviceTree = {
    enable = true;
    name = "rockchip/rk3568-rock-3b.dtb";
    overlays = [
      {
        name = "rock3b-pwm-fan";
        dtsText = ''
          /dts-v1/;
          /plugin/;

          / {
            compatible = "radxa,rock-3b";

            fragment@0 {
              target = <&pwm8>;
              __overlay__ {
                pinctrl-names = "default";
                pinctrl-0 = <&pwm8m0_pins>;
                status = "okay";
              };
            };

            fragment@1 {
              target-path = "/";
              __overlay__ {
                fan: pwm-fan {
                  compatible = "pwm-fan";
                  pwms = <&pwm8 0 40000 0>;
                  cooling-levels = <0 115 179 255>;
                  #cooling-cells = <2>;
                  fan-stop-to-start-percent = <70>;
                  fan-stop-to-start-us = <500000>;
                  fan-shutdown-percent = <100>;
                };
              };
            };
          };
        '';
      }
      {
        name = "rock3b-rtl8211f-gmac0";
        dtsText = ''
          /dts-v1/;
          /plugin/;
          / {
            compatible = "radxa,rock-3b";
            fragment@0 {
              /* gmac0 = fe2a0000 = end0 */
              target-path = "/ethernet@fe2a0000/mdio/ethernet-phy@1";
              __overlay__ {
                compatible = "ethernet-phy-id001c.c916";
                reset-deassert-us = <80000>;
              };
            };
          };
        '';
      }
    ];
  };

  systemd.services.rock3b-fan-controller = {
    description = "Control the ROCK 3B fan from CPU temperature";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${fanController}/bin/rock3b-fan-controller";
      Restart = "always";
      RestartSec = 2;
    };
  };

  systemd.services.rock3b-ethernet-leds = {
    description = "Configure ROCK 3B RTL8211F Ethernet LEDs";

    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];

    after = [
      "network-online.target"
      "sys-subsystem-net-devices-end0.device"
      "sys-subsystem-net-devices-end1.device"
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      ${configureEthernetLeds}/bin/rock3b-configure-ethernet-leds end0
      ${configureEthernetLeds}/bin/rock3b-configure-ethernet-leds end1
    '';
  };
}
