# BlackArch auto-update pipeline

`.github/workflows/auto-update.yml` + the scripts in this directory keep the
~4600 PKGBUILDs in `packages/` up to date with almost no human work:

```
detect (1 job, ~15 min)          build (N shards, ≤20 parallel)        publish (1 job)            report (1 job)
──────────────────────           ───────────────────────────           ──────────────             ─────────────
meta-all.sh   read+lint all  ──► build-shard.sh                   ──►  publish.sh            ──►  report.py
detect.py scan  nvchecker.toml     per package, fresh container:        commit PKGBUILDs            report.md/.json artifact
nvchecker     upstream versions      bump → updpkgsums / pkgver()       push to master              job summary
probe-sources (Sundays)              verifysource → makepkg -s          scripts/barelease           one tracking issue
detect.py plan  shards               pacman -U install test             (sign + repo-add + rsync)   seen-cache for next run
```

## What it does

* **Detection without committed state.** "Old" versions are read from the
  PKGBUILDs every run (no `oldver.json` to commit, nothing lost when a run
  fails). Release packages are compared with pacman's `vercmp` rules (ported
  to Python), so downgrades and odd tags are never applied. VCS packages
  (`pkgver()` + git source, ~1800) are checked with `git ls-remote` against the
  commit hash already in `pkgver` — no cloning unless something changed.
* **Supported upstreams** (generated automatically from the source URLs):
  GitHub tags, GitLab tags, PyPI, RubyGems, CPAN, SourceForge (RSS), git
  commits. On the current tree this tracks ~3150 of 4613 packages. Anything
  else can be added by hand in `nvchecker-overrides.toml`; the report lists
  the most common untracked hosts so you know where an override pays off.
* **Clean builds.** Every package builds in its own throw-away
  `blackarchlinux/blackarch:base-devel` container (same base as
  `travis/Dockerfile`), so missing `makedepends` are caught, then the result
  is installed with `pacman -U` to catch missing runtime deps and file
  conflicts. Build jobs have **no secrets**: upstream code runs there.
* **Failures are not retried every day.** A package that failed for upstream
  version X is skipped (but still listed in the report as "previous run")
  until upstream moves past X, 7 days pass, or you run with `retry_failed`.
* **Publishing** reuses `scripts/barelease` unchanged (lock, repo-add, sign,
  rsync, banotify). Commits are `"<pkg>: auto-update to <ver>."` with
  `[skip ci]`. If the upload fails after the push, the packages are appended
  to `lists/to-release` so the normal release flow picks them up.

## Publish modes (`PUBLISH_MODE`)

| | `push` (default) | `pr` |
|---|---|---|
| Where commits go | straight to `master` | branch `auto-update/<date>-<run>`, **one PR per run** |
| When packages are uploaded | right after the push | when the PR is merged (`auto-update-release.yml`) |
| Rebuild on merge? | – | no: the packages built by the run are uploaded |
| Reviewer drops/edits a package | – | it is not uploaded; it goes to `lists/to-release` |
| Packages already in an open PR | – | skipped by later runs until the PR is merged/closed |

In `pr` mode build artifacts are kept 14 days; merge within that window or
the packages land in `lists/to-release` for a manual build. Squash, rebase
and merge commits all work (the release step compares file contents). Set the
mode with the repository variable `PUBLISH_MODE`, or per run with the
`publish_mode` input. If PRs are opened with the default token, enable
*Settings → Actions → Allow GitHub Actions to create and approve pull
requests*, or set `BA_BOT_TOKEN`.

## Relation to tests.yml

`tests.yml` (pkgcheck + Docker build of the PKGBUILDs changed in a PR) is left
untouched and still guards human PRs. The bot's commits carry `[skip ci]`, so
it doesn't run on them; instead this pipeline does the same checks itself,
for the whole tree:

* `pkgcheck-all.sh` runs the same `pkgcheck` (pkgcheck-arch) on **every**
  PKGBUILD each day (results under "invalid PKGBUILD structure").
* every update is built in a fresh container like `travis/Dockerfile`
  does, **plus** an install test with `pacman -U`.

## Whole-repo build status (rolling audit)

Besides updated packages, each run builds `audit` (default 300, variable
`AUDIT_PER_RUN`) other packages exactly as they are on master: never-tested
packages first, then PKGBUILDs changed since their last test, then the
oldest results. That is a full pass over all ~4600 packages roughly every two
weeks. Audit builds are never published.

The last result for every package is kept in a status database (Actions
cache, also copied into each report as `status-db.json`) together with a
fingerprint of the PKGBUILD it was built from. So the report lists **all**
currently failing packages, not just the ones touched today; a failure
disappears as soon as the package builds again, and a package whose
PKGBUILD was changed by a human is re-tested first. The summary shows for
how many packages the status is known (it starts at 0 and fills up during
the first cycle).

## Reverse dependencies and removal help

`detect.py` builds a dependency graph of the tree (`depgraph.json` in the
report artifact) from `depends`, `makedepends`, `checkdepends` and
`optdepends` (including `*_x86_64` arrays and `provides`). Split packages
are resolved per output: `depends=()` inside `package_python2-foo()`
replaces the top-level one, like makepkg does. For every package that fails
to build or has broken sources the report shows who needs which output and
a verdict:

* ✅ nothing in BlackArch needs it / only optional (optdepends)
* ⚠️ only needed by other failing packages (remove them together)
* ❌ needed by N working packages

Two extra sections use the same graph: **Removal candidates** (failing and
not needed by any working package) and **Python 2 packages that nothing
hard-depends on**, which lists every `python2-*` output, including the
`python2-` half of a `python-`/`python2-` pkgbase, with the suggested action
("drop `package_python2-foo()` from `python-foo`" or "remove package").
Only the BlackArch tree is considered; something an end user installs
directly, or an AUR package that depends on it, is invisible here.

## Report

Artifact `auto-update-report` (and the issue labelled `auto-update-report`):

| Section | Sources |
|---|---|
| ❌ fail to build | makepkg errors, dependency install failures, install test, timeouts |
| 🔗 invalid / broken sources | `updpkgsums`/`--verifysource` failures, dead git repos (ls-remote), weekly URL probe (404/410/DNS/refused/bad TLS) |
| 🧩 invalid / unexpected PKGBUILD | `pkgcheck` (as in tests.yml), `bash -n`, sourcing errors, `makepkg --printsrcinfo` lint, name ≠ dir, invalid pkgver/pkgrel, checksum count ≠ source count, missing `package()`, sources that don't use `$pkgver`, pkgver computed after the `pkgver=` line, upstream versions that aren't valid pkgvers |

Plus 🗑️ removal candidates and 🐍 unused Python 2 packages (see above).
`report.json` has the same data machine-readable, `depgraph.json` the full
reverse-dependency graph, `status-db.json` the last build result of every
package, and `logs/<pkg>/build.log` the (truncated) log of every build.

A dry run of the static checks on today's tree already finds real bugs, e.g.
`python-textract`, `python-pylzma`, `python-wayback` (syntax error in
`sha512sums`), `sploitego`, `vidalia` (2 checksums, 1 source),
`perl-crypt-curve25519` (pkgname is `perl-net-tftp`).

## Setup

1. Copy `.github/ci/` and `.github/workflows/auto-update.yml` into the repo.
2. **Signing key.** Create a dedicated signing key (e.g. "BlackArch CI"),
   sign it with the master key and **add it to `blackarch-keyring`** —
   otherwise users' pacman rejects every package it signs. Never put a
   developer's personal key into CI.
3. **Upload account.** A dedicated SSH user on blackarch.org that can only
   write the repo directory (and run what barelease/banotify run).
4. Create the environment **`blackarch-repo`** (Settings → Environments). Add
   required reviewers there if you want a human click before each upload.
   * secrets: `REPO_GPG_PRIVATE_KEY` (armored), `REPO_GPG_PASSPHRASE`
     (optional), `REPO_SSH_PRIVATE_KEY`, `BA_BOT_TOKEN` (optional: GitHub App
     / fine-grained token allowed to push to protected `master`)
   * variables: `REPO_GPG_KEY_ID`, `REPO_SSH_USER`, `REPO_SSH_KNOWN_HOSTS`
     (output of `ssh-keyscan blackarch.org`), optional `REPO_SITE`,
     `REPO_SITEDIR` (barelease `-s`/`-d`)
5. Repository variables: `AUTO_PUBLISH=true` turns publishing on for the
   daily run (default **off**: builds and reports only). `PUBLISH_MODE=pr`
   opens a PR instead of pushing (see above). `AUTO_RELEASE=false` commits
   PKGBUILDs but puts the packages in `lists/to-release` instead of
   uploading. `REPORT_ISSUE=false` disables the tracking issue.

### Suggested rollout

1. Merge with `AUTO_PUBLISH` unset → a week of build-and-report only; fix or
   override what the report shows.
2. `AUTO_PUBLISH=true`, `PUBLISH_MODE=pr` → one PR a day; merging it releases.
3. `PUBLISH_MODE=push` → fully automatic.

The first run will find many VCS packages behind; `max_updates` (default 250)
caps each run and the rest is picked up the following days.

## Manual runs (Actions → Auto-update packages → Run workflow)

* `packages: "foo bar"` — update these if upstream is newer, else rebuild
  them with `pkgrel+1` (handy after a library soname bump).
* `publish: false` — test without touching master or the repo.
* `publish_mode: pr|push` — override `PUBLISH_MODE` for this run.
* `probe_sources: true` — run the URL probe now.
* `retry_failed: true` — ignore the failure cache.

## Tuning files

* `exclude.txt` — never auto-update (seeded from the EX list in
  `scripts/up-vcs-tools`); `lists/to-remove` is honoured too, and package
  names matching `^python2-|-py2$` are skipped (pinned legacy libraries;
  change with `--exclude-regex`).
* `nvchecker-overrides.toml` — hand-written nvchecker entries win over the
  generated ones.

## Limits / ideas for later

* Only x86_64 is built. `any` packages go to both arches through barelease
  as today; aarch64-specific builds could use `ubuntu-24.04-arm` runners
  with an arm builder image.
* Packages are built against the repo as it is; if a library and a tool that
  needs the new library update in the same run, the tool may fail once and
  succeed next run.
* Builds needing >14 GB disk or >60 min (`PER_PKG_TIMEOUT`) will be reported
  as failures; exclude them or give them a larger self-hosted runner.
