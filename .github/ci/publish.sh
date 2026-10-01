#!/usr/bin/env bash
# publish.sh - hand successfully built updates over, in one of two modes:
#
#   PUBLISH_MODE=push  commit to master, push, then release right away with
#                      scripts/barelease (default)
#   PUBLISH_MODE=pr    commit to a branch and open ONE pull request for the
#                      whole run; release-merged.sh uploads the packages when
#                      that PR is merged (workflow auto-update-release.yml)
#
# Runs in the publish job (blackarch container, repo checked out, as root).
# Env:
#   BASE_SHA            commit the run started from (detect job)
#   RESULTS PKGS        downloaded results/ and pkgs/ artifact dirs
#   PUBLISH_OUT         where to write publish.json for the report
#   RUN_ID RUN_URL      this workflow run
#   GH_TOKEN GH_REPO    for `gh pr create` (pr mode)
#   + release env, see lib-release.sh (push mode)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-release.sh
. "$here/lib-release.sh"

MODE=${PUBLISH_MODE:-push}
[[ $MODE == push || $MODE == pr ]] || { echo "unknown PUBLISH_MODE '$MODE'"; exit 1; }

committed=() skipped=() released=false release_error="" pr_url=""
write_out() {
  jq -n --arg mode "$MODE" --arg pr_url "$pr_url" \
        --argjson committed "$(printf '%s\n' "${committed[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
        --argjson skipped "$(printf '%s\n' "${skipped[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
        --argjson released "$released" --arg release_error "$release_error" \
        '{mode:$mode, pr_url:$pr_url, committed:$committed, skipped:$skipped,
          released:$released, release_error:$release_error}' > "$PUBLISH_OUT"
}
trap write_out EXIT

# ------------------------------------------------------------------ select
mapfile -t ok < <(
  for s in "$RESULTS"/*/status.json; do
    jq -r 'select(.result=="ok" and .kind!="test") | .pkg' "$s"   # audit builds are never published
  done | sort)
echo "built OK: ${#ok[@]}  (mode: $MODE)"
(( ${#ok[@]} )) || exit 0

git config --global --add safe.directory "$PWD"
git config user.name  "blackarch-ci[bot]"
git config user.email "team@blackarch.org"
git fetch --quiet origin master
git fetch --quiet --depth=1 origin "$BASE_SHA" 2>/dev/null || true

todo=()
for pkg in "${ok[@]}"; do
  if [[ ! -f $RESULTS/$pkg/PKGBUILD ]] || ! compgen -G "$PKGS/$pkg/*.pkg.tar.zst" >/dev/null; then
    skipped+=("$pkg: build artifacts missing"); continue
  fi
  if ! git diff --quiet "$BASE_SHA" origin/master -- "packages/$pkg"; then
    skipped+=("$pkg: changed on master during the run"); continue
  fi
  todo+=("$pkg")
done

# ------------------------------------------------------------------ commit
if [[ $MODE == pr ]]; then
  branch="auto-update/$(date -u +%Y-%m-%d)-$RUN_ID"
else
  branch=master
fi
git checkout -q -B "$branch" origin/master
for pkg in "${todo[@]}"; do
  cp "$RESULTS/$pkg/PKGBUILD" "packages/$pkg/PKGBUILD"
  git add "packages/$pkg/PKGBUILD"
  git diff --cached --quiet && { skipped+=("$pkg: no diff"); continue; }
  ver=$(jq -r .pkgver "$RESULTS/$pkg/status.json")
  git commit -q -m "$pkg: auto-update to $ver." \
    -m "Built in a clean container and install-tested by $RUN_URL" -m "[skip ci]"
  committed+=("$pkg")
done
(( ${#committed[@]} )) || exit 0

# ------------------------------------------------------------------ pr mode
if [[ $MODE == pr ]]; then
  git push -q origin "HEAD:refs/heads/$branch"
  body=$(mktemp)
  {
    echo "<!-- auto-update-run-id: $RUN_ID -->"
    echo "Automated update of **${#committed[@]}** packages. Each one was bumped,"
    echo "built in a clean container and install-tested with \`pacman -U\`"
    echo "([run]($RUN_URL), build logs in the \`auto-update-report\` artifact)."
    echo
    echo "**Merging this PR uploads the already-built packages to the repo.**"
    echo "Drop a commit (or edit a PKGBUILD) to keep a package out: it will be"
    echo "added to \`lists/to-release\` for a manual build instead."
    echo
    echo "| Package | From | To |"
    echo "|---|---|---|"
    for pkg in "${committed[@]}"; do
      jq -r '"| `\(.pkg)` | \(.cur) | \(.pkgver) |"' "$RESULTS/$pkg/status.json"
    done
    if (( ${#skipped[@]} )); then
      echo
      echo "<details><summary>Not included (${#skipped[@]})</summary>"
      echo
      printf -- '- %s\n' "${skipped[@]}"
      echo "</details>"
    fi
  } > "$body"
  head -c 60000 "$body" > "$body.cut"
  gh label create auto-update --color 0075ca \
    --description "Automated PKGBUILD updates" 2>/dev/null || true
  pr_url=$(gh pr create --base master --head "$branch" --label auto-update \
    --title "auto-update: ${#committed[@]} packages ($(date -u +%Y-%m-%d))" \
    --body-file "$body.cut")
  echo "opened $pr_url"
  exit 0
fi

# ------------------------------------------------------------------ push mode
for try in 1 2 3; do
  git push -q origin HEAD:master && break
  (( try == 3 )) && { committed=(); echo "push failed"; exit 1; }
  git fetch -q origin master
  git rebase -q origin/master || { git rebase --abort; committed=(); echo "rebase conflict"; exit 1; }
done
echo "pushed ${#committed[@]} commits"

release_packages "${committed[@]}"
