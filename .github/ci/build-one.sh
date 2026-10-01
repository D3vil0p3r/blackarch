#!/usr/bin/env bash
# build-one.sh - runs INSIDE a fresh builder container for ONE package.
#
#   /build   writable copy of packages/<pkg>/   (cwd)
#   /out     results: status.json, build.log, PKGBUILD, pkgs/*.pkg.tar.zst
#   env      PKG KIND(release|vcs|rebuild|test) CUR NEW
#
# Phases: bump -> verify sources -> build (makepkg -s) -> install test.
# The container is thrown away afterwards, so every package gets a clean
# system and missing (make)depends are caught. No secrets are ever present.

set -uo pipefail
cd /build || exit 1
mkdir -p /out/pkgs
LOG=/out/build.log
: > "$LOG"
START=$(date +%s)

status() { # status <result> <reason> [new_pkgver]
  jq -n --arg pkg "$PKG" --arg kind "$KIND" --arg cur "$CUR" --arg target "$NEW" \
        --arg result "$1" --arg reason "$2" --arg pkgver "${3:-}" \
        --argjson secs "$(( $(date +%s) - START ))" \
        --arg tail "$(tail -n 40 "$LOG" | cut -c1-300)" \
        '{pkg:$pkg, kind:$kind, cur:$cur, target:$target, result:$result,
          reason:$reason, pkgver:$pkgver, seconds:$secs, log_tail:$tail}' > /out/status.json
  echo "==> [$PKG] $1: $2" | tee -a "$LOG"
  exit 0
}

run() { # run <label> <cmd...> ; logs, returns the command's exit code
  echo "==> $1" >> "$LOG"
  shift
  "$@" >> "$LOG" 2>&1
}

pkgver_of() { ( source ./PKGBUILD >/dev/null 2>&1; echo "${pkgver:-}" ); }
sources_of() { makepkg --printsrcinfo 2>/dev/null | grep -E '^\s*source(_[a-z0-9_]+)? = ' ; }

# makepkg exit codes (libmakepkg/util/error.sh)
classify_makepkg() { # <rc> <phase>
  case $1 in
    8|15) status build_failed "dependencies could not be installed ($2, rc=$1)" ;;
    12)   status pkgbuild_invalid "makepkg rejected the PKGBUILD ($2, rc=$1)" ;;
    4)    status build_failed "a PKGBUILD function failed ($2, rc=$1)" ;;
    *)    status build_failed "makepkg failed ($2, rc=$1)" ;;
  esac
}

before_src=$(sources_of) || status pkgbuild_invalid "makepkg --printsrcinfo failed"
[[ $(grep -cE '^pkgrel=' PKGBUILD) == 1 ]] || status pkgbuild_invalid "PKGBUILD does not have exactly one 'pkgrel=' line"

# ---------------------------------------------------------------- bump
case $KIND in
  release)
    [[ $(grep -cE '^pkgver=' PKGBUILD) == 1 ]] || status pkgbuild_invalid "PKGBUILD does not have exactly one 'pkgver=' line"
    [[ $NEW =~ ^[A-Za-z0-9._+]+$ ]] || status pkgbuild_invalid "upstream version '$NEW' is not a valid pkgver"
    sed -i -E "s|^pkgver=.*|pkgver=$NEW|; s|^pkgrel=.*|pkgrel=1|" PKGBUILD
    [[ $(pkgver_of) == "$NEW" ]] || status pkgbuild_invalid "pkgver is computed after the 'pkgver=' line; cannot bump automatically"
    after_src=$(sources_of) || status pkgbuild_invalid "PKGBUILD broken after bump"
    [[ $before_src != "$after_src" ]] ||
      status pkgbuild_invalid "sources do not depend on \$pkgver (hard-coded version or URL)"
    run "updpkgsums" updpkgsums || status source_broken "cannot download new sources (updpkgsums)"
    ;;
  vcs)
    # fetch + run pkgver() only; cheap way to learn whether anything changed
    run "makepkg -od (fetch + pkgver)" makepkg -od --noprepare --noconfirm
    rc=$?
    case $rc in
      0) ;;
      4) status pkgbuild_invalid "pkgver() failed" ;;
      12) status pkgbuild_invalid "makepkg rejected the PKGBUILD (rc=12)" ;;
      *) status source_broken "cannot fetch VCS source (rc=$rc)" ;;
    esac
    newver=$(pkgver_of)
    [[ $newver =~ ^[A-Za-z0-9._+]+$ ]] || status pkgbuild_invalid "pkgver() produced invalid version '$newver'"
    [[ $newver != "$CUR" ]] || status no_change "pkgver() still returns $CUR"
    sed -i -E "s|^pkgrel=.*|pkgrel=1|" PKGBUILD
    ;;
  test)
    ;;  # rolling audit: build the PKGBUILD exactly as it is on master
  rebuild)
    rel=$(sed -nE "s/^pkgrel=[\"']?([0-9]+)[\"']?\s*$/\1/p" PKGBUILD)
    [[ $rel =~ ^[0-9]+$ ]] || status pkgbuild_invalid "cannot bump non-integer pkgrel for a rebuild"
    sed -i -E "s|^pkgrel=.*|pkgrel=$(( rel + 1 ))|" PKGBUILD
    ;;
esac

# ---------------------------------------------------------------- sources
if [[ $KIND != vcs ]]; then
  run "makepkg --verifysource" makepkg --verifysource -f --noconfirm ||
    status source_broken "source download or integrity check failed"
fi

# ---------------------------------------------------------------- build
run "makepkg -s" makepkg -s -f --noconfirm --needed --noprogressbar
rc=$?
(( rc == 0 )) || classify_makepkg "$rc" build

shopt -s nullglob
pkgs=(./*.pkg.tar.zst)
(( ${#pkgs[@]} )) || status build_failed "makepkg succeeded but produced no .pkg.tar.zst"

# ---------------------------------------------------------------- install test
# resolves runtime depends against the real repos and catches file conflicts
run "pacman -U (install test)" sudo pacman -U --noconfirm "${pkgs[@]}" ||
  status build_failed "built package does not install (missing runtime deps or file conflicts)"

if command -v namcap >/dev/null; then
  run "namcap" namcap "${pkgs[@]}" || true
fi

cp "${pkgs[@]}" /out/pkgs/
cp PKGBUILD /out/PKGBUILD
status ok "built and installed" "$(pkgver_of)"
