{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "ryzen-forgejo-runners";
  nodes.machine = {
    imports = [
      ../hosts/ryzen/runner.nix
      ../hosts/ryzen/nix-ci.nix
    ];
    services.forgejo = {
      enable = true;
      package = pkgs.forgejo;
      settings = {
        server.HTTP_ADDR = "127.0.0.1";
        actions.ENABLED = true;
      };
    };
    environment.systemPackages = [ pkgs.curl ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("forgejo.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3000/api/v1/version")
    machine.succeed("install -d -m 700 /srv/forgejo /etc/forgejo-runner /var/lib/nix-cache; touch /srv/forgejo/.migration-ready /var/lib/nix-cache/signing-key")
    machine.succeed("su -s /bin/sh forgejo -c 'FORGEJO_WORK_DIR=/var/lib/forgejo ${pkgs.forgejo}/bin/forgejo actions generate-runner-token' > /etc/forgejo-runner/web.env")
    machine.succeed("sed 's/^/TOKEN=/' /etc/forgejo-runner/web.env > /etc/forgejo-runner/nix.env; chmod 600 /etc/forgejo-runner/*.env")

    with subtest("both runners register with Forgejo using either token format"):
        for name in ["web", "nix"]:
            machine.succeed(f"systemctl start gitea-runner-{name}")
            machine.wait_for_unit(f"gitea-runner-{name}.service")
            machine.wait_until_succeeds(f"journalctl -u gitea-runner-{name} | grep 'registered successfully'")

    with subtest("the Nix runner writes registration state as its dedicated account"):
        machine.succeed("test $(systemctl show -p User --value gitea-runner-nix) = nix-ci")
        machine.succeed("sudo -u nix-ci test -s /var/lib/gitea-runner-nix/nix/.runner")
        machine.succeed("sudo -u nix-ci test -s /var/lib/gitea-runner-nix/nix/.token-hash")
        machine.succeed("sudo -u nix-ci test -s /var/lib/gitea-runner-nix/nix/.labels")
        machine.fail("sudo -u nix-ci test -r /var/lib/gitea-runner/web/.runner")

    with subtest("restarts reuse each runner's registration"):
        paths = "/var/lib/gitea-runner/web/.runner /var/lib/gitea-runner-nix/nix/.runner"
        before = machine.succeed(f"sha256sum {paths}")
        machine.succeed("systemctl restart gitea-runner-web gitea-runner-nix")
        for name in ["web", "nix"]:
            machine.wait_for_unit(f"gitea-runner-{name}.service")
        assert machine.succeed(f"sha256sum {paths}") == before

    with subtest("failed registration does not write success metadata"):
        machine.succeed("systemctl stop gitea-runner-web; rm /var/lib/gitea-runner/web/{.runner,.token-hash,.labels}; printf invalid > /etc/forgejo-runner/web.env")
        machine.fail("systemctl start gitea-runner-web")
        machine.succeed("systemctl stop gitea-runner-web")
        for path in [".runner", ".token-hash", ".labels"]:
            machine.succeed(f"test ! -e /var/lib/gitea-runner/web/{path}")
  '';
}
