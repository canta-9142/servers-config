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
    import json

    start_all()
    machine.wait_for_unit("forgejo.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3000/api/v1/version")
    machine.succeed("install -d -m 700 /srv/forgejo /etc/forgejo-runner /var/lib/nix-cache; touch /srv/forgejo/.migration-ready /var/lib/nix-cache/signing-key")
    machine.succeed("su -s /bin/sh forgejo -c 'FORGEJO_WORK_DIR=/var/lib/forgejo ${pkgs.forgejo}/bin/forgejo actions generate-runner-token' > /etc/forgejo-runner/web.env")
    machine.succeed("sed 's/^/TOKEN=/' /etc/forgejo-runner/web.env > /etc/forgejo-runner/nix.env; chmod 600 /etc/forgejo-runner/*.env")

    with subtest("both runners register with Forgejo using either token format"):
        for name in ["web", "nix"]:
            machine.succeed(f"systemctl start forgejo-runner-{name}")
            machine.wait_for_unit(f"forgejo-runner-{name}.service")
            machine.wait_until_succeeds(f"journalctl -u forgejo-runner-{name} | grep 'registered successfully'")
            machine.wait_until_succeeds(f"journalctl -u forgejo-runner-{name} | grep 'declared successfully'")

    with subtest("runtime connections reuse the private registration credentials"):
        for name, state in [("web", "/var/lib/gitea-runner/web"), ("nix", "/var/lib/gitea-runner-nix/nix")]:
            registration = machine.succeed(f"cat {state}/.runner")
            runtime_path = f"/run/forgejo-runner/{name}/config.json"
            registered = json.loads(registration)
            connection = json.loads(machine.succeed(f"cat {runtime_path}"))["server"]["connections"]["default"]
            assert connection["uuid"] == registered["uuid"]
            assert connection["token"] == registered["token"]
            machine.succeed(f"test $(stat -c %a {runtime_path}) = 600")
            machine.fail(f"sudo -u nobody cat {runtime_path}")

    with subtest("the Nix runner writes registration state as its dedicated account"):
        machine.succeed("test $(systemctl show -p User --value forgejo-runner-nix) = nix-ci")
        machine.succeed("sudo -u nix-ci test -s /var/lib/gitea-runner-nix/nix/.runner")
        machine.succeed("sudo -u nix-ci test -s /var/lib/gitea-runner-nix/nix/.token-hash")
        machine.succeed("sudo -u nix-ci test -s /var/lib/gitea-runner-nix/nix/.labels")
        machine.fail("sudo -u nix-ci test -r /var/lib/gitea-runner/web/.runner")

    with subtest("restarts reuse each runner's registration"):
        paths = "/var/lib/gitea-runner/web/.runner /var/lib/gitea-runner-nix/nix/.runner"
        before = machine.succeed(f"sha256sum {paths}")
        machine.succeed("systemctl restart forgejo-runner-web forgejo-runner-nix")
        for name in ["web", "nix"]:
            machine.wait_for_unit(f"forgejo-runner-{name}.service")
        assert machine.succeed(f"sha256sum {paths}") == before

    with subtest("failed registration does not write success metadata"):
        machine.succeed("systemctl stop forgejo-runner-web; rm /var/lib/gitea-runner/web/{.runner,.token-hash,.labels}; printf invalid > /etc/forgejo-runner/web.env")
        machine.fail("systemctl start forgejo-runner-web")
        machine.succeed("systemctl stop forgejo-runner-web")
        for path in [".runner", ".token-hash", ".labels"]:
            machine.succeed(f"test ! -e /var/lib/gitea-runner/web/{path}")
  '';
}
