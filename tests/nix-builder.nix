{ pkgs }:
let
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
in
pkgs.testers.runNixOSTest {
  name = "nix-remote-builder";
  nodes = {
    server = { config, lib, ... }: {
      imports = [
        ../modules/system/ssh.nix
        ../modules/system/nix-builder.nix
      ];
      nix.enable = true;
      users.users.nix-builder.openssh.authorizedKeys.keys = lib.mkForce [
        ''restrict,command="${config.nix.package}/bin/nix-daemon --stdio" ${keys.snakeOilEd25519PublicKey}''
      ];
      services.openssh.hostKeys = lib.mkForce [
        {
          path = "/etc/ssh/test_host_key";
          type = "ed25519";
        }
      ];
      environment.etc."ssh/test_host_key" = {
        source = keys.snakeOilEd25519PrivateKey;
        mode = "0600";
      };
    };
    client = {
      nix = {
        enable = true;
        distributedBuilds = true;
        settings = {
          experimental-features = [ "nix-command" ];
          max-jobs = 0;
          builders-use-substitutes = true;
          substituters = pkgs.lib.mkForce [ ];
        };
        buildMachines = [
          {
            hostName = "server";
            protocol = "ssh-ng";
            sshUser = "nix-builder";
            sshKey = "/root/builder-key";
            system = "x86_64-linux";
            maxJobs = 1;
            supportedFeatures = [ "big-parallel" ];
          }
        ];
      };
      programs.ssh.knownHosts.server.publicKey = keys.snakeOilEd25519PublicKey;
      programs.ssh.extraConfig = ''
        Host server
          BatchMode yes
          StrictHostKeyChecking yes
          ConnectTimeout 2
      '';
      system.extraDependencies = [ pkgs.bash ];
      environment.etc."build.nix".text = ''
        { name }: builtins.derivation {
          inherit name;
          system = "x86_64-linux";
          builder = builtins.storePath "${pkgs.bash}" + "/bin/bash";
          args = [ "-c" "echo built > $out" ];
          allowSubstitutes = false;
          requiredSystemFeatures = [ "big-parallel" ];
        }
      '';
    };
  };
  testScript = ''
    start_all()
    server.wait_for_unit("sshd.service")
    client.succeed("install -m600 ${keys.snakeOilEd25519PrivateKey} /root/builder-key")
    def build(name, options=""):
        return f"nix build --impure --file /etc/build.nix --argstr name {name} --no-link --print-out-paths {options}"
    with subtest("remote build using the restricted dedicated account"):
        output = client.succeed(build("remote-probe") + " 2>&1")
        assert "on 'ssh-ng://nix-builder@server'" in output, output
        client.succeed("test $(cat " + output.strip().splitlines()[-1] + ") = built")
    with subtest("unavailable builder requires explicit local execution"):
        server.succeed("systemctl stop sshd.service")
        client.fail(build("offline-probe"), timeout=60)
        client.succeed(build("offline-probe", '--builders "" --max-jobs 1'))
    with subtest("normal commands use the builder again after recovery"):
        server.succeed("systemctl start sshd.service")
        server.wait_for_unit("sshd.service")
        output = client.succeed(build("recovered-probe") + " 2>&1")
        assert "on 'ssh-ng://nix-builder@server'" in output, output
  '';
}
