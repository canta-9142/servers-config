set +x
set -euo pipefail

: "${CACHE_UPDATE_TOKEN:?Run from the scheduled Actions job}"
: "${CACHE_UPDATE_RUN_URL:?Missing workflow run URL}"
# Only discard changes produced by this job, never pre-existing tracked changes.
git diff --quiet
git diff --cached --quiet

for attempt in 1 2 3; do
  echo "Preparing lock update (attempt $attempt/3)"
  git fetch --no-tags origin main
  base=$(git rev-parse FETCH_HEAD)
  git checkout --detach --force "$base"
  nix flake update --accept-flake-config
  if ! git diff --quiet -- flake.lock; then
    git -c user.name=nix-cache-updater \
      -c user.email=nix-cache-updater@floating-gate.com \
      commit -m 'chore: update flake.lock [skip ci]' -- flake.lock
  fi
  candidate=$(git rev-parse HEAD)

  nix build --accept-flake-config --no-update-lock-file \
    --max-jobs 1 --cores 8 \
    .#nixosConfigurations.nixos.config.system.build.toplevel --out-link result
  system_path=$(readlink -f result)
  sudo -n /run/current-system/sw/bin/nix-cache-publish "$system_path"
  test -s hosts/laptop/nix-cache.pub
  nix store verify --no-contents --recursive --sigs-needed 1 \
    --store https://cache.floating-gate.com \
    --option trusted-public-keys "$(cat hosts/laptop/nix-cache.pub)" "$system_path"

  if [[ $candidate == "$base" ]]; then
    # Even without a lock change, do not report verification for an outdated tip.
    git fetch --no-tags origin main
    if [[ $(git rev-parse FETCH_HEAD) != "$base" ]]; then
      continue
    fi
  elif ! git push origin "$candidate:refs/heads/main"; then
    git fetch --no-tags origin main
    latest=$(git rev-parse FETCH_HEAD)
    if git merge-base --is-ancestor "$candidate" "$latest"; then
      # The push reached Forgejo but its acknowledgement may have been lost.
      echo "Verified update is already present on origin/main"
    elif [[ $latest != "$base" ]]; then
      echo "main advanced; updating and rebuilding its latest configuration"
      continue
    else
      echo "Push failed without a competing update; leaving main unchanged" >&2
      exit 1
    fi
  fi

  # The scheduled run is attached to its starting SHA. Record success on the
  # actual verified commit too, because [skip ci] suppresses a duplicate build.
  status=$(jq -n --arg url "$CACHE_UPDATE_RUN_URL" \
    '{state: "success", context: "Nix cache / lock update", description: "Laptop closure built, published and verified", target_url: $url}')
  if ! curl --fail --silent --show-error --retry 3 --retry-all-errors \
    --header "Authorization: token $CACHE_UPDATE_TOKEN" \
    --header 'Content-Type: application/json' --data "$status" \
    "https://git.floating-gate.com/api/v1/repos/jinji/nixos-config/statuses/$candidate" \
    --output /dev/null; then
    echo "Cache verified, but commit status reporting failed; check the workflow log" >&2
    exit 1
  fi
  echo "Verified commit: $candidate; system: $system_path"
  exit 0
done

echo "main advanced during all three attempts; no update was pushed by this job" >&2
exit 1
