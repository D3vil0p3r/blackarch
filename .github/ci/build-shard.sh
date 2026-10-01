#!/usr/bin/env bash
# build-shard.sh <shard.json> <packages-dir> <results-dir> <pkgs-dir>
#
# Runs on the GitHub runner host. Builds every package of one shard, each in
# its own fresh container (image "ba-builder"), with a per-package timeout and
# a shard-wide time budget so the 6h job limit is never hit.
#
#   results-dir/<pkg>/{status.json,build.log,PKGBUILD}   small, for the report
#   pkgs-dir/<pkg>/*.pkg.tar.zst                         big, for publishing
set -uo pipefail

shard=$1 pkgsrc=$2 results=$3 pkgout=$4
PER_PKG_TIMEOUT=${PER_PKG_TIMEOUT:-60m}
BUDGET_SECS=${BUDGET_SECS:-$(( 5 * 3600 ))}     # stop starting builds after 5h
MIN_FREE_GB=${MIN_FREE_GB:-8}
CACHE=${PACMAN_CACHE:-$PWD/.pacman-cache}
mkdir -p "$results" "$pkgout" "$CACHE"
chmod 777 "$CACHE"
t0=$(date +%s)

write_status() { # <pkg> <kind> <cur> <new> <result> <reason>
  jq -n --arg pkg "$1" --arg kind "$2" --arg cur "$3" --arg target "$4" \
        --arg result "$5" --arg reason "$6" \
        '{pkg:$pkg, kind:$kind, cur:$cur, target:$target, result:$result, reason:$reason}' \
        > "$results/$1/status.json"
}

jq -c '.[]' "$shard" | while read -r u; do
  pkg=$(jq -r .pkg <<<"$u"); kind=$(jq -r .kind <<<"$u")
  cur=$(jq -r .cur <<<"$u"); new=$(jq -r .new <<<"$u")
  mkdir -p "$results/$pkg"
  echo "::group::$pkg ($kind: $cur -> $new)"

  if (( $(date +%s) - t0 > BUDGET_SECS )); then
    write_status "$pkg" "$kind" "$cur" "$new" skipped "shard time budget exhausted; retried next run"
    echo "::endgroup::"; continue
  fi
  free_gb=$(df -BG --output=avail "$PWD" | tail -1 | tr -dc 0-9)
  if (( free_gb < MIN_FREE_GB )); then
    sudo rm -rf "$CACHE"/* ; docker system prune -af >/dev/null 2>&1 || true
    docker image inspect ba-builder >/dev/null 2>&1 || { echo "builder image gone"; exit 1; }
  fi

  work=$(mktemp -d)
  cp -a "$pkgsrc/$pkg/." "$work/"
  mkdir -p "$work/.out"
  chmod -R a+rwX "$work"

  timeout --kill-after=2m "$PER_PKG_TIMEOUT" \
    docker run --rm --name "build-$pkg" \
      -e PKG="$pkg" -e KIND="$kind" -e CUR="$cur" -e NEW="$new" \
      -v "$work:/build" -v "$work/.out:/out" \
      -v "$CACHE:/var/cache/pacman/pkg" \
      ba-builder < /dev/null
  rc=$?
  if (( rc == 124 || rc == 137 )); then
    docker rm -f "build-$pkg" >/dev/null 2>&1
    cp "$work/.out/build.log" "$results/$pkg/" 2>/dev/null
    write_status "$pkg" "$kind" "$cur" "$new" build_failed "timed out after $PER_PKG_TIMEOUT"
  elif [[ -s $work/.out/status.json ]]; then
    cp "$work/.out/status.json" "$results/$pkg/"
    [[ -f $work/.out/PKGBUILD ]] && cp "$work/.out/PKGBUILD" "$results/$pkg/"
    if [[ $kind != test ]] && compgen -G "$work/.out/pkgs/*.pkg.tar.zst" >/dev/null; then
      mkdir -p "$pkgout/$pkg"
      cp "$work/.out/pkgs/"*.pkg.tar.zst "$pkgout/$pkg/"
    fi
  else
    write_status "$pkg" "$kind" "$cur" "$new" build_failed "builder container crashed (rc=$rc)"
  fi
  # keep logs small: first 200 + last 2500 lines
  if [[ -f $work/.out/build.log ]]; then
    if (( $(wc -l < "$work/.out/build.log") > 2700 )); then
      { head -n 200 "$work/.out/build.log"; echo "[... truncated ...]"
        tail -n 2500 "$work/.out/build.log"; } > "$results/$pkg/build.log"
    else
      cp "$work/.out/build.log" "$results/$pkg/build.log"
    fi
  fi
  jq -r '"result: \(.result) - \(.reason)"' "$results/$pkg/status.json"
  sudo rm -rf "$work"
  echo "::endgroup::"
done
