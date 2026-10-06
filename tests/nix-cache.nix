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
    imports = [
      ../hosts/ryzen/nix-cache.nix
      ../hosts/ryzen/nix-ci.nix
    ];
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
    with subtest("the Nix runner waits for registration and uses a separate account"):
        machine.succeed("test $(systemctl show -p User --value gitea-runner-nix) = nix-ci")
        machine.fail("systemctl is-active gitea-runner-nix")
        machine.fail("sudo -u nix-ci sudo -n true")
    machine.succeed("install -d -m 700 -o nix-ci -g nix-ci /var/lib/gitea-runner-nix/nix")
    with subtest("the untrusted CI account can build through the Nix daemon"):
        machine.succeed("sudo -u nix-ci env NIX_REMOTE=daemon nix-build --no-out-link --expr 'derivation { name = \"ci-build-probe\"; system = builtins.currentSystem; shell = builtins.storePath \"${pkgs.bash}\"; builder = \"${pkgs.bash}/bin/bash\"; args = [ \"-c\" \"echo ci-build > $out\" ]; }'")
    with subtest("publishing requires arguments and a signing key"):
        machine.fail("nix-cache-publish")
        machine.fail(f"nix-cache-publish {artifact}")
        machine.fail("nix-cache-publish nixpkgs#hello")
        machine.fail("sudo -u nix-ci sudo -n /run/current-system/sw/bin/nix-cache-publish /nix/store/../../tmp/flake")
        machine.fail("sudo -u nix-ci sudo -n /run/current-system/sw/bin/nix-cache-publish /nix/store/00000000000000000000000000000000-missing")
        machine.fail(f"sudo -u nobody nix-cache-publish {artifact}")
    machine.succeed("umask 077; nix key generate-secret --key-name cache-test-1 > /var/lib/nix-cache/signing-key")
    key = machine.succeed("nix key convert-secret-to-public < /var/lib/nix-cache/signing-key").strip()
    with subtest("signed publication includes the closure"):
        machine.fail("sudo -u nix-ci cat /var/lib/nix-cache/signing-key")
        machine.fail("sudo -u nix-ci touch /srv/nix-cache/forbidden")
        machine.succeed(f"sudo -u nix-ci sudo -n /run/current-system/sw/bin/nix-cache-publish {artifact}")
        machine.succeed(f"curl -fsS {url}/nix-cache-info")
        machine.succeed("ss -lnt | grep '127.0.0.1:8081'")
        machine.succeed(f"nix copy --from {url} --to 'local?root=/tmp/cache-client' --option trusted-public-keys '{key}' {artifact}")
        machine.succeed(f"test -f /tmp/cache-client{artifact}/dependency; test -f /tmp/cache-client{dependency}")
        machine.succeed(f"sudo -u nix-ci nix store verify --no-contents --recursive --sigs-needed 1 --store {url} --option trusted-public-keys '{key}' {artifact}")
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
