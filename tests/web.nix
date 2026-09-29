{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "ryzen-web";
  nodes.machine = {
    imports = [ ../hosts/ryzen/web.nix ];
    # Exercise nginx without contacting Cloudflare or needing credentials.
    services.cloudflared.tunnels."aa088497-b776-4cb2-989e-935dc02ed6b3".credentialsFile =
      "/nonexistent";
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("nginx.service")
    machine.wait_for_open_port(8080)
    url = "http://127.0.0.1:8080"
    root = "/srv/www/floating-gate"
    with subtest("an uninitialized site is not healthy"):
        assert machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {url}/healthz") == "503"
        machine.succeed("ss -lnt | grep '127.0.0.1:8080'")
    with subtest("nginx follows atomic release switches"):
        machine.succeed(f"sudo -u site-deploy sh -c 'mkdir {root}/releases/first; echo first > {root}/releases/first/index.html; ln -s releases/first {root}/current'")
        assert machine.succeed(f"curl -fsS {url}/") == "first\n"
        assert machine.succeed(f"curl -fsS {url}/healthz") == "ok\n"
        machine.succeed(f"mkdir {root}/.staging/second; echo second > {root}/.staging/second/index.html")
        assert machine.succeed(f"curl -fsS {url}/") == "first\n"
        machine.fail(f"curl -fsS {url}/.staging/second/index.html")
        machine.succeed(f"mv {root}/.staging/second {root}/releases/second; ln -s releases/second {root}/.staging/current; mv -Tf {root}/.staging/current {root}/current")
        assert machine.succeed(f"curl -fsS {url}/") == "second\n"
        machine.succeed("systemd-tmpfiles --create; systemctl restart nginx")
        machine.wait_for_open_port(8080)
        assert machine.succeed(f"curl -fsS {url}/") == "second\n"
        machine.succeed(f"rm {root}/releases/second/index.html")
        assert machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {url}/healthz") == "503"
  '';
}
