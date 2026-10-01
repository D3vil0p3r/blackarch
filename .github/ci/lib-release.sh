#!/usr/bin/env bash
# lib-release.sh - sourced by publish.sh and release-merged.sh.
#
# release_packages <pkg>...   signs and uploads $PKGS/<pkg>/*.pkg.tar.zst with
#                             scripts/barelease; sets $released / $release_error.
# queue_for_humans <msg> <pkg>...  appends packages to lists/to-release on
#                             master so the normal release flow picks them up.
#
# Env: PKGS GPG_KEY_ID GPG_PRIVATE_KEY [GPG_PASSPHRASE] SSH_PRIVATE_KEY
#      SSH_KNOWN_HOSTS SSH_USER [REPO_SITE] [REPO_SITEDIR] [RELEASE=true|false]

# shellcheck disable=SC2034  # released/release_error are read by the caller
release_packages() {
  (( $# )) || return 0
  if [[ ${RELEASE:-true} != true ]]; then
    release_error="AUTO_RELEASE=false: packages added to lists/to-release for a manual release"
    queue_for_humans "auto-update packages awaiting manual release" "$@"
    return
  fi

  export HOME=${HOME:-/root}
  export GNUPGHOME
  GNUPGHOME=$(mktemp -d); chmod 700 "$GNUPGHOME"
  echo allow-preset-passphrase > "$GNUPGHOME/gpg-agent.conf"
  gpg --batch --quiet --import <<<"$GPG_PRIVATE_KEY"
  if [[ -n ${GPG_PASSPHRASE:-} ]]; then
    gpgconf --launch gpg-agent
    for grip in $(gpg --with-keygrip -K "$GPG_KEY_ID" | awk '/Keygrip/ {print $3}'); do
      /usr/lib/gnupg/gpg-preset-passphrase --preset -P "$GPG_PASSPHRASE" "$grip"
    done
  fi
  export GPG_AGENT_INFO=preset   # tell barelease an agent is already running
  # barelease checks the key is in pacman's keyring (users must have it via
  # blackarch-keyring for the signatures to be trusted!)
  gpg --export "$GPG_KEY_ID" | pacman-key --add - >/dev/null
  pacman-key --lsign-key "$GPG_KEY_ID" >/dev/null

  mkdir -p ~/.ssh; chmod 700 ~/.ssh
  printf '%s\n' "$SSH_KNOWN_HOSTS" > ~/.ssh/known_hosts
  eval "$(ssh-agent -s)" >/dev/null
  ssh-add -q - <<<"$SSH_PRIVATE_KEY"

  local files=() pkg rc
  for pkg in "$@"; do files+=("$PKGS/$pkg"/*.pkg.tar.zst); done
  local args=(-k "$GPG_KEY_ID" -u "$SSH_USER")
  [[ -n ${REPO_SITE:-} ]] && args+=(-s "$REPO_SITE")
  [[ -n ${REPO_SITEDIR:-} ]] && args+=(-d "$REPO_SITEDIR")

  set +e
  timeout 90m ./scripts/barelease "${args[@]}" "${files[@]}"
  rc=$?
  set -e
  ssh-agent -k >/dev/null 2>&1 || true

  if (( rc == 0 )); then
    released=true
  else
    # PKGBUILDs are already on master, so no run will rebuild them:
    # hand them to the normal human release flow instead of losing them.
    release_error="barelease failed (rc=$rc); packages added to lists/to-release"
    queue_for_humans "auto-update packages awaiting release" "$@" ||
      release_error+=" (and pushing lists/to-release failed!)"
    return 1
  fi
}

queue_for_humans() {
  local msg=$1; shift
  (( $# )) || return 0
  git fetch -q origin master
  git checkout -q -B master origin/master
  printf '%s\n' "$@" >> lists/to-release
  sort -u -o lists/to-release lists/to-release
  git add lists/to-release
  git diff --cached --quiet && return 0
  git commit -q -m "lists/to-release: $msg" -m "[skip ci]"
  git push -q origin HEAD:master
}
