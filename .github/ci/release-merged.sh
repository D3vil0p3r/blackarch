#!/usr/bin/env bash
# release-merged.sh - runs when an auto-update PR is merged
# (workflow auto-update-release.yml). Uploads the packages that the original
# run built, but only for PKGBUILDs that reached master exactly as built.
# Anything changed during review, or whose build artifacts expired, goes to
# lists/to-release for the normal manual flow.
#
# Env: PR_NUMBER RESULTS PKGS GH_TOKEN GH_REPO + release env (lib-release.sh)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-release.sh
. "$here/lib-release.sh"

released=false release_error=""
git config --global --add safe.directory "$PWD"
git config user.name  "blackarch-ci[bot]"
git config user.email "team@blackarch.org"
git fetch -q origin master
git checkout -q -B master origin/master

mapfile -t changed < <(
  gh api --paginate "repos/$GH_REPO/pulls/$PR_NUMBER/files" -q '.[].filename' |
    sed -nE 's|^packages/([^/]+)/PKGBUILD$|\1|p' | sort -u)

ship=() manual=()
for pkg in "${changed[@]}"; do
  if [[ -f packages/$pkg/PKGBUILD && -f $RESULTS/$pkg/PKGBUILD ]] &&
     cmp -s "packages/$pkg/PKGBUILD" "$RESULTS/$pkg/PKGBUILD" &&
     compgen -G "$PKGS/$pkg/*.pkg.tar.zst" >/dev/null; then
    ship+=("$pkg")
  elif [[ -f packages/$pkg/PKGBUILD ]]; then
    manual+=("$pkg")
  fi
done
echo "release: ${#ship[@]}  manual: ${#manual[@]}"

rc=0
release_packages "${ship[@]}" || rc=1
if (( ${#manual[@]} )); then
  queue_for_humans "auto-update PR #$PR_NUMBER: changed in review or artifacts expired" \
    "${manual[@]}" || rc=1
fi

{
  if [[ $released == true ]]; then
    echo "✅ Released ${#ship[@]} packages to the repo."
  elif (( ${#ship[@]} )); then
    echo "⚠️ Packages were not released: ${release_error:-unknown error}"
  fi
  if (( ${#manual[@]} )); then
    echo
    echo "Added to \`lists/to-release\` (changed during review or build artifacts expired):"
    printf -- '- `%s`\n' "${manual[@]}"
  fi
} > comment.md
[[ -s comment.md ]] && gh pr comment "$PR_NUMBER" --body-file comment.md || true
exit "$rc"
