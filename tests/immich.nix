{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "ryzen-immich";

  nodes = {
    server = {
      imports = [ ../hosts/ryzen/immich.nix ];
      system.stateVersion = "26.05";
      networking.nftables.enable = true;
      networking.firewall.checkReversePath = "loose";
      virtualisation = {
        vlans = [
          1
          2
        ];
        cores = 2;
        memorySize = 4096;
        diskSize = 4096;
      };
    };
    client = {
      environment.systemPackages = [ pkgs.netcat-openbsd ];
      networking.firewall.checkReversePath = "loose";
      virtualisation.vlans = [
        1
        2
      ];
    };
  };

  testScript = ''
    import json

    start_all()
    server.wait_for_unit("immich-server.service")
    server.wait_for_unit("immich-machine-learning.service")
    server.wait_until_succeeds("curl -fsS http://127.0.0.1:2283/api/server/ping")
    server.wait_for_open_port(3003)

    with subtest("media is private and the API works with the local database"):
        assert server.succeed("stat -c '%a %U %G' /srv/immich").strip() == "700 immich immich"
        server.succeed("curl -fsS --json '{\"email\":\"test@example.org\",\"name\":\"Admin\",\"password\":\"immich-test-password\"}' http://127.0.0.1:2283/api/auth/admin-sign-up")
        login = "curl -fsS --json '{\"email\":\"test@example.org\",\"password\":\"immich-test-password\"}' http://127.0.0.1:2283/api/auth/login"
        token = json.loads(server.succeed(login))["accessToken"]

    with subtest("Immich accepts only Mesh sources targeting the Mesh address"):
        client.wait_for_unit("multi-user.target")
        client.succeed("ip addr add 100.96.0.2/24 dev eth1")
        server.succeed("ip addr add 100.96.0.1/24 dev eth1")
        client.succeed("curl -fsS --connect-timeout 3 --interface 100.96.0.2 http://100.96.0.1:2283/api/server/ping")
        lan_ip = client.succeed("ip -4 -o addr show dev eth1").split()[3].split('/')[0]
        server_lan_ip = server.succeed("ip -4 -o addr show dev eth1").split()[3].split('/')[0]
        client.fail(f"nc -z -w 3 -s {lan_ip} 100.96.0.1 2283")
        client.fail(f"nc -z -w 3 -s 100.96.0.2 {server_lan_ip} 2283")
        client.fail(f"nc -z -w 3 {server_lan_ip} 2283")
        for port in (3003, 5432, 6379):
            client.fail(f"nc -z -w 3 -s 100.96.0.2 100.96.0.1 {port}")

    with subtest("Immich accepts the home LAN only on its physical interface and LAN address"):
        # VLAN 1 models Mesh; VLAN 2 models the separate home LAN.
        server.succeed("ip link set eth2 down; ip link set eth2 name enp39s0; ip link set enp39s0 up")
        server.succeed("ip addr add 192.168.11.201/24 dev enp39s0")
        client.succeed("ip addr add 192.168.11.202/24 dev eth2")
        client.succeed("curl -fsS --connect-timeout 3 --interface 192.168.11.202 http://192.168.11.201:2283/api/server/ping")
        # A different private subnet is not part of the home LAN allowlist.
        other_ip = client.succeed("ip -4 -o addr show dev eth2").split()[3].split('/')[0]
        client.fail(f"nc -z -w 3 -s {other_ip} 192.168.11.201 2283")
        client.fail("nc -z -w 3 -s 192.168.11.202 100.96.0.1 2283")
        client.fail("nc -z -w 3 -s 100.96.0.2 192.168.11.201 2283")
        for port in (3003, 5432, 6379):
            client.fail(f"nc -z -w 3 -s 192.168.11.202 192.168.11.201 {port}")
        # Even a home LAN source must not be accepted through another interface.
        client.succeed(f"ip route add 192.168.11.201/32 via {server_lan_ip} dev eth1")
        client.fail("nc -z -w 3 -s 192.168.11.202 192.168.11.201 2283")

    with subtest("Immich can create its built-in database backup"):
        server.succeed("curl -fsS -X PUT -H 'Cookie: immich_access_token=%s' --json '{\"command\":\"start\"}' http://127.0.0.1:2283/api/jobs/backupDatabase" % token)
        server.wait_until_succeeds("find /srv/immich/backups -name '*.sql.gz' | grep .")
        server.succeed("gzip -t /srv/immich/backups/*.sql.gz")

    with subtest("the documented manual backup restores media and accounts"):
        server.succeed("sudo -u immich touch /srv/immich/persistence-check")
        server.succeed("systemctl stop immich-server.service immich-machine-learning.service")
        server.succeed("sudo -u postgres pg_dump --format=custom immich > /tmp/database.dump")
        server.succeed("tar --acls --xattrs -C /srv -cpf /tmp/media.tar immich")
        server.succeed("sudo -u postgres pg_restore --clean --if-exists --single-transaction --exit-on-error --dbname=immich < /tmp/database.dump")
        server.succeed("mv /srv/immich /srv/immich.before-restore")
        server.succeed("tar --acls --xattrs -C /srv -xpf /tmp/media.tar; chown -R immich:immich /srv/immich")
        server.succeed("systemctl restart postgresql.service redis-immich.service")
        server.succeed("systemctl start immich-server.service immich-machine-learning.service")
        server.wait_until_succeeds(login)
        server.succeed("test -f /srv/immich/persistence-check")
  '';
}
