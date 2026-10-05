{ pkgs }:
let
  dependency = pkgs.runCommand "cache-test-dependency" { } ''
    echo dependency > "$out"
  '';
  artifact = pkgs.runCommand "cache-test-artifact" { } ''
    mkdir "$out"
    echo ${dependency} > "$out/dependency"
  '';
in
pkgs.testers.runNixOSTest {
  name = "ryzen-nix-cache";
  nodes.machine = {
    imports = [ ../hosts/ryzen/nix-cache.nix ];
    services.cloudflared.tunnels."aa088497-b776-4cb2-989e-935dc02ed6b3".credentialsFile =
      "/nonexistent";
    environment.systemPackages = [ pkgs.curl ];
    # Ensure the artifact and its dependency are available without network access.
    system.extraDependencies = [ artifact ];
    nix.settings.experimental-features = [ "nix-command" ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("nginx.service")
    machine.wait_for_open_port(8081)
    url = "http://127.0.0.1:8081"
    artifact = "${artifact}"
    dependency = "${dependency}"
    with subtest("publishing requires arguments and a signing key"):
        machine.fail("nix-cache-publish")
        machine.fail(f"nix-cache-publish {artifact}")
        machine.fail("nix-cache-publish nixpkgs#hello")
        machine.fail(f"sudo -u nobody nix-cache-publish {artifact}")
    machine.succeed("umask 077; nix key generate-secret --key-name cache-test-1 > /var/lib/nix-cache/signing-key")
    key = machine.succeed("nix key convert-secret-to-public < /var/lib/nix-cache/signing-key").strip()
    with subtest("signed publication includes the closure"):
        machine.succeed(f"nix-cache-publish {artifact}")
        machine.succeed(f"curl -fsS {url}/nix-cache-info")
        machine.succeed("ss -lnt | grep '127.0.0.1:8081'")
        machine.succeed(f"nix copy --from {url} --to 'local?root=/tmp/cache-client' --option trusted-public-keys '{key}' {artifact}")
        machine.succeed(f"test -f /tmp/cache-client{artifact}/dependency; test -f /tmp/cache-client{dependency}")
    with subtest("a different key cannot authorize the cache"):
        wrong_key = machine.succeed("nix key generate-secret --key-name wrong-1 | nix key convert-secret-to-public").strip()
        machine.fail(f"nix copy --from {url} --to 'local?root=/tmp/wrong-key-client' --option trusted-public-keys '{wrong_key}' {artifact}")
    with subtest("HTTP cannot publish or list cache files"):
        machine.fail(f"curl -fsS -X PUT --data bad {url}/malicious.narinfo")
        machine.fail(f"curl -fsS {url}/")
        machine.fail(f"curl -fsS {url}/signing-key")
        assert "no-store" in machine.succeed(f"curl -sSI {url}/missing.narinfo")
    with subtest("store GC does not remove the separate cache"):
        machine.succeed("nix-store --gc")
        machine.succeed(f"nix copy --from {url} --to 'local?root=/tmp/after-gc-client' --option trusted-public-keys '{key}' {artifact}")
    with subtest("unavailable cache permits a local build with fallback"):
        machine.succeed("systemctl stop nginx")
        machine.succeed("nix-build --store 'local?root=/var/lib/fallback-client' --option substituters 'http://127.0.0.1:8081' --option fallback true --option connect-timeout 1 --option download-attempts 1 --option builders \"\" --option max-jobs 1 --option sandbox false --no-out-link --expr 'derivation { name = \"fallback-test\"; system = builtins.currentSystem; builder = \"/bin/sh\"; args = [ \"-c\" \"echo fallback > $out\" ]; }'")
  '';
}
