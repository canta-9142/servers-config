{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "forgejo-migration";

  nodes = {
    source = {
      services.forgejo = {
        enable = true;
        package = pkgs.forgejo;
        lfs.enable = true;
        settings = {
          server = {
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = 3000;
            START_SSH_SERVER = true;
            SSH_LISTEN_PORT = 2223;
          };
          actions.ENABLED = true;
        };
      };
      networking.firewall.allowedTCPPorts = [ 8000 ];
      environment.systemPackages = [ pkgs.netcat-openbsd ];
    };
    target = {
      imports = [ ../hosts/ryzen/forgejo.nix ];
      networking.nftables.enable = true;
    };
  };

  testScript = ''
    import json

    start_all()
    target.wait_for_unit("multi-user.target")
    with subtest("activation cannot initialize a fresh Forgejo instance"):
        target.fail("systemctl is-active forgejo.service")
        target.fail("systemctl is-active forgejo-dump.timer")
        target.succeed("test ! -e /srv/forgejo/data/forgejo.db")
        target.succeed("test ! -e /srv/forgejo/custom/conf/secret_key")
        target.succeed("touch /srv/forgejo/.migration-ready")
        target.fail("systemctl start forgejo.service")
        target.succeed("test ! -e /srv/forgejo/custom/conf/secret_key")
        target.succeed("rm /srv/forgejo/.migration-ready; systemctl reset-failed")

    with subtest("restore a stopped instance including its account and keys"):
        source.wait_for_unit("forgejo.service")
        source.wait_until_succeeds("curl -fsS http://127.0.0.1:3000/api/v1/version")
        source.succeed("su -s /bin/sh forgejo -c 'FORGEJO_WORK_DIR=/var/lib/forgejo FORGEJO_CUSTOM=/var/lib/forgejo/custom ${pkgs.forgejo}/bin/forgejo admin user create --username migration-user --password migration-test-password --email test@example.org --must-change-password=false'")
        source.succeed("curl -fsS -u migration-user:migration-test-password -H 'Content-Type: application/json' -d '{\"name\":\"migration-repo\"}' http://127.0.0.1:3000/api/v1/user/repos")
        source.succeed("systemctl stop forgejo.service")
        keys = "custom/conf/secret_key custom/conf/internal_token custom/conf/oauth2_jwt_secret custom/conf/lfs_jwt_secret data/ssh/gitea.rsa data/jwt/private.pem data/actions_id_token/private.pem"
        before = source.succeed(f"cd /var/lib/forgejo && sha256sum {keys}")
        source.succeed("mkdir /tmp/export; tar -C /var/lib/forgejo -cf /tmp/export/forgejo.tar .")
        source.succeed("systemd-run --unit=export ${pkgs.python3}/bin/python3 -m http.server 8000 --directory /tmp/export")
        source.wait_for_open_port(8000)
        target.succeed("curl -fsS http://source:8000/forgejo.tar -o /tmp/forgejo.tar")
        target.succeed("tar -xpf /tmp/forgejo.tar -C /srv/forgejo; chown -R forgejo:forgejo /srv/forgejo")
        target.succeed("systemd-tmpfiles --create; touch /srv/forgejo/.migration-ready; systemctl start forgejo.service forgejo-dump.timer")
        target.wait_for_unit("forgejo.service")
        target.wait_until_succeeds("curl -fsS http://127.0.0.1:3000/api/v1/version")
        after = target.succeed(f"cd /srv/forgejo && sha256sum {keys}")
        assert before == after, "Migration replaced an existing secret or SSH host key"
        repo = json.loads(target.succeed("curl -fsS http://127.0.0.1:3000/api/v1/repos/migration-user/migration-repo"))
        assert repo["clone_url"] == "https://git.floating-gate.com/migration-user/migration-repo.git", repo
        assert repo["ssh_url"] == "ssh://git@ryzen.home.arpa:2222/migration-user/migration-repo.git", repo
        target.succeed("systemctl is-active forgejo-dump.timer")
        target.succeed("systemctl start forgejo-dump.service")
        target.succeed("find /var/backup/forgejo -name '*.tar.zst' | grep .")

    with subtest("Git SSH is reachable only via the Mesh destination and sources"):
        source.succeed("ip addr add 100.96.0.2/24 dev eth1")
        target.succeed("ip addr add 100.96.0.1/24 dev eth1")
        source.succeed("nc -z -w 3 -s 100.96.0.2 100.96.0.1 2222")
        lan_ip = source.succeed("ip -4 -o addr show dev eth1").split()[3].split('/')[0]
        target_lan_ip = target.succeed("ip -4 -o addr show dev eth1").split()[3].split('/')[0]
        source.fail(f"nc -z -w 3 -s {lan_ip} 100.96.0.1 2222")
        source.fail(f"nc -z -w 3 -s 100.96.0.2 {target_lan_ip} 2222")
        source.fail(f"nc -z -w 3 {target_lan_ip} 3000")
  '';
}
