#!/usr/bin/env python3
"""
report.py - final report of an auto-update run.

  report.py --state DIR --results DIR [--publish FILE] [--seen-in FILE]
            --seen-out FILE --out DIR [--run-url URL]

Writes into --out:
  report.json   everything, machine readable
  report.md     full report (all rows, build-log tails)
  issue.md      same, trimmed to fit a GitHub issue / job summary
and --seen-out: the status database for the next run
  packages{}    last update attempt per package (skip same failing version)
  builds{}      last build result of each package's *current* PKGBUILD
                (rolling audit + successful updates) -> whole-repo status

For every package that fails to build or has broken sources, the report shows
which BlackArch packages need it (depends / makedepends / checkdepends /
optdepends, per split package) and whether it can be removed safely.
"""
import argparse
import datetime as dt
import hashlib
import json
from collections import Counter
from pathlib import Path

CATS = ("build_failed", "source_broken", "pkgbuild_invalid")
FAILING = ("build_failed", "source_broken")
HARD = ("depends", "makedepends", "checkdepends")
TITLES = {
    "build_failed": "Packages that fail to build",
    "source_broken": "Packages with invalid / broken sources",
    "pkgbuild_invalid": "Packages with invalid or unexpected PKGBUILD structure",
}
SHORT = {"depends": "dep", "makedepends": "make", "checkdepends": "check", "optdepends": "opt"}


def esc(s) -> str:
    return str(s).replace("|", "\\|").replace("\n", " ").strip()


def load(path, default):
    p = Path(path) if path else None
    return json.loads(p.read_text()) if p and p.exists() else default


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--results", required=True)
    ap.add_argument("--publish")
    ap.add_argument("--seen-in")
    ap.add_argument("--seen-out", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--run-url", default="")
    a = ap.parse_args()

    st, out, res_dir = Path(a.state), Path(a.out), Path(a.results)
    out.mkdir(parents=True, exist_ok=True)
    now = dt.datetime.now(dt.timezone.utc)
    today = now.isoformat(timespec="seconds")
    issues = load(st / "issues.json", [])
    plan = load(st / "updates.json", {})
    for k in ("updates", "audit", "carried", "deferred", "pending"):
        plan.setdefault(k, [])
    untracked = load(st / "untracked.json", {})
    tracking = load(st / "tracking.json", {})
    meta = load(st / "meta.json", {})
    graph = load(st / "depgraph.json", {})
    publish = load(a.publish, {})
    db = load(a.seen_in, {})
    seen, builds = db.get("packages", {}), db.get("builds", {})

    # ------------------------------------------------------------ results
    planned = {u["pkg"]: u for u in plan["updates"] + plan["audit"]}
    results = {}
    for f in res_dir.glob("*/status.json"):
        r = json.loads(f.read_text())
        results[r["pkg"]] = r
    for p, u in planned.items():   # shard died / was cancelled
        results.setdefault(p, {**u, "target": u["new"], "result": "skipped",
                               "reason": "no result (build job failed or was cancelled)"})

    # ------------------------------------------------------------ status db
    for p, r in results.items():
        if r["result"] == "skipped":
            continue
        if r["result"] == "no_change":   # remembered so the VCS clone isn't repeated daily
            seen[p] = {"target": r["target"], "result": "no_change", "reason": r["reason"],
                       "date": today, "run_url": a.run_url}
            continue
        rec = {"result": r["result"], "reason": r["reason"], "kind": r["kind"],
               "pkgver": r.get("pkgver") or r["cur"], "date": today, "run_url": a.run_url}
        f = res_dir / p / "PKGBUILD"
        if r["result"] == "ok" and r["kind"] != "test" and f.exists():
            # the bumped PKGBUILD is what goes to master
            builds[p] = {**rec, "sha": hashlib.sha1(f.read_bytes()).hexdigest()}
        elif r["kind"] in ("test", "rebuild"):
            builds[p] = {**rec, "sha": planned.get(p, {}).get("sha", "")}
        if r["kind"] != "test":
            seen[p] = {"target": r["target"], "result": r["result"], "reason": r["reason"],
                       "date": today, "run_url": a.run_url}
    builds = {p: b for p, b in builds.items() if p in meta}
    # updated OK this run: the fingerprint is of the bumped PKGBUILD, which only
    # reaches master after publishing, so count it as known too
    updated_now = {p for p, r in results.items() if r["result"] == "ok" and r["kind"] != "test"}
    known = {p: b for p, b in builds.items()
             if b.get("sha") == meta[p].get("sha") or p in updated_now}
    stale = len(builds) - len(known)

    # ------------------------------------------------------------ problem lists
    lists = {c: [] for c in CATS}
    this_run = set()
    for r in results.values():
        if r["result"] in CATS:
            this_run.add(r["pkg"])
            upd = "current PKGBUILD" if r["kind"] in ("test", "rebuild") else f'{r["cur"]} → {r["target"]}'
            lists[r["result"]].append({"pkg": r["pkg"], "found_by": "build " + r["kind"],
                                       "severity": "error", "detail": r["reason"], "update": upd,
                                       "since": today[:10], "log_tail": r.get("log_tail", "")})
    for c in plan["carried"]:
        if c.get("result") in CATS:
            lists[c["result"]].append({"pkg": c["pkg"], "found_by": "update (earlier run)",
                                       "severity": "error", "detail": c.get("reason", ""),
                                       "update": f'{c["cur"]} → {c["new"]}',
                                       "since": (c.get("date") or "")[:10], "log_tail": "",
                                       "run_url": c.get("run_url")})
    for p, b in known.items():
        if b["result"] in CATS and p not in this_run:
            lists[b["result"]].append({"pkg": p, "found_by": "audit build", "severity": "error",
                                       "detail": b["reason"], "update": "current PKGBUILD",
                                       "since": b["date"][:10], "log_tail": "",
                                       "run_url": b.get("run_url")})
    warnings = []
    for i in issues:
        if i["category"] in CATS:
            lists[i["category"]].append({"pkg": i["pkg"], "found_by": i["check"],
                                         "severity": i["severity"], "detail": i["message"],
                                         "update": "", "since": today[:10], "log_tail": ""})
        else:
            warnings.append(i)

    # ------------------------------------------------------------ reverse deps
    failing = {x["pkg"] for c in FAILING for x in lists[c] if x["severity"] == "error"}

    def rdeps(p):
        return [r for r in graph.get(p, {}).get("rdeps", []) if r["pkg"] != p]

    def verdict(p):
        rd = rdeps(p)
        hard = {r["pkg"] for r in rd if r["type"] in HARD}
        if not rd:
            return "safe", "✅ nothing in BlackArch needs it"
        if not hard:
            return "safe", "✅ only optional (optdepends)"
        blockers = sorted(hard - failing)
        if not blockers:
            return "with-dependents", "⚠️ only needed by failing packages: " + ", ".join(sorted(hard))
        return "needed", f"❌ needed by {len(blockers)} working package(s)"

    def needed_by(p, limit=8):
        names = graph.get(p, {}).get("names", {})
        parts = []
        multi = len(names) > 1
        for n, rs in sorted(names.items()):
            rs = [r for r in rs if r["pkg"] != p]
            if not rs and not multi:
                continue
            items = []
            for r in rs[:limit]:
                mark = "❌" if r["pkg"] in failing else ""
                items.append(f'{mark}{r["pkg"]} ({SHORT.get(r["type"], r["type"])})')
            if len(rs) > limit:
                items.append(f"+{len(rs) - limit} more")
            parts.append((f"`{n}` ← " if multi else "") + (", ".join(items) if items else "nothing"))
        prov = [r for r in rdeps(p) if r["name"] not in names]
        if prov:   # via provides=()
            parts.append("via provides: " + ", ".join(f'{r["pkg"]} ({SHORT.get(r["type"])})'
                                                     for r in prov[:limit]))
        return "; ".join(parts) or "—"

    for c in CATS:
        for x in lists[c]:
            x["needed_by"] = [{k: r[k] for k in ("pkg", "type", "name", "via")} for r in rdeps(x["pkg"])]
            x["removable"], x["verdict"] = verdict(x["pkg"])
        lists[c].sort(key=lambda x: (x["severity"] != "error", x["pkg"]))

    removal = []
    for p in sorted(failing):
        kind, text = verdict(p)
        if kind != "needed":
            probs = sorted({c for c in FAILING for x in lists[c] if x["pkg"] == p})
            removal.append({"pkg": p, "problem": ", ".join(probs), "verdict": text,
                            "kind": kind, "produces": sorted(graph.get(p, {}).get("names", {})),
                            "needed_by": needed_by(p)})

    py2 = []
    for d, g in sorted(graph.items()):
        for n, rs in sorted(g["names"].items()):
            if not n.startswith("python2-"):
                continue
            rs = [r for r in rs if r["pkg"] != d]
            if any(r["type"] in HARD for r in rs):
                continue
            others = sorted(x for x in g["names"] if x != n)
            b = known.get(d)
            py2.append({"name": n, "dir": d, "also_builds": others,
                        "build": (b["result"] if b else "unknown") if d not in failing else "failing",
                        "optdepends_of": sorted({r["pkg"] for r in rs}),
                        "action": (f"drop package_{n}() from {d}" if others
                                   else f"remove package {d}")})

    published = set(publish.get("committed", [])) if publish.get("released") else set()
    committed = set(publish.get("committed", []))
    ok = sorted((r for r in results.values() if r["result"] == "ok" and r["kind"] != "test"),
                key=lambda r: r["pkg"])
    audit_ok = sum(1 for r in results.values() if r["kind"] == "test" and r["result"] == "ok")
    oldest = min((b["date"] for b in known.values()), default="")[:10]

    totals = {
        "packages": len(meta), "tracked": len(tracking), "untracked": len(untracked),
        "updates_planned": len(plan["updates"]), "deferred": len(plan["deferred"]),
        "waiting_in_pr": len(plan["pending"]), "audit_builds": len(plan["audit"]),
        "audit_ok": audit_ok, "build_status_known": len(known), "build_status_stale": stale,
        "built_ok": len(ok), "committed": len(committed), "released": len(published),
        "no_change": sum(r["result"] == "no_change" for r in results.values()),
        "skipped": sum(r["result"] == "skipped" for r in results.values()),
        **{c: len({x["pkg"] for x in lists[c]}) for c in CATS},
        "removal_candidates": len(removal), "python2_unused": len(py2),
    }
    report = {"generated": today, "run_url": a.run_url, "totals": totals, **lists,
              "removal_candidates": removal, "python2_without_hard_dependents": py2,
              "updated": [{"pkg": r["pkg"], "from": r["cur"], "to": r.get("pkgver") or r["target"],
                           "committed": r["pkg"] in committed, "released": r["pkg"] in published}
                          for r in ok],
              "publish": publish, "warnings": warnings,
              "untracked_by_reason": Counter(untracked.values()).most_common()}
    (out / "report.json").write_text(json.dumps(report, indent=1))

    # ------------------------------------------------------------ markdown
    def md(full: bool) -> str:
        lim = None if full else 120
        t = totals
        L = [f"# BlackArch auto-update report — {now:%Y-%m-%d}", ""]
        if a.run_url:
            L += [f"Run: {a.run_url} — full report and logs in the `auto-update-report` artifact", ""]
        L += ["| | |", "|---|---:|",
              f"| Packages / tracked upstream | {t['packages']} / {t['tracked']} |",
              f"| Updates found (deferred to next run) | {t['updates_planned']} ({t['deferred']}) |",
              f"| Built + install-tested OK | {t['built_ok']} |",
              f"| Committed / released | {t['committed']} / {t['released']} |",
              f"| Waiting in open auto-update PRs | {t['waiting_in_pr']} |",
              f"| Audit builds this run (OK) | {t['audit_builds']} ({t['audit_ok']}) |",
              f"| Build status known for current PKGBUILDs | {t['build_status_known']} / {t['packages']}"
              + (f" (oldest {oldest})" if oldest else "") + " |",
              f"| ❌ Fail to build | {t['build_failed']} |",
              f"| 🔗 Broken sources | {t['source_broken']} |",
              f"| 🧩 Invalid PKGBUILD structure | {t['pkgbuild_invalid']} |",
              f"| 🗑️ Failing and safe(ish) to remove | {t['removal_candidates']} |",
              f"| 🐍 python2 packages nothing hard-depends on | {t['python2_unused']} |", ""]
        if publish.get("pr_url"):
            L += [f"> 📬 **Pull request:** {publish['pr_url']} — packages are released when it is merged.", ""]
        if publish.get("release_error"):
            L += [f"> ⚠️ **Release:** {publish['release_error']}", ""]

        for c, icon in zip(CATS, ("❌", "🔗", "🧩")):
            rows = lists[c]
            L += [f"## {icon} {TITLES[c]} ({len({x['pkg'] for x in rows})})", ""]
            if not rows:
                L += ["None 🎉", ""]
                continue
            if c in FAILING:
                L += ["| Package | Found by | Update | Details | Needed by (in BlackArch) | Removable? |",
                      "|---|---|---|---|---|---|"]
                for x in rows[:lim]:
                    L.append(f"| `{x['pkg']}` | {esc(x['found_by'])} (since {x['since']}) | {esc(x['update'])} "
                             f"| {esc(x['detail'])[:220]} | {esc(needed_by(x['pkg']))} | {esc(x['verdict'])} |")
            else:
                L += ["| Package | Severity | Check | Details |", "|---|---|---|---|"]
                for x in rows[:lim]:
                    L.append(f"| `{x['pkg']}` | {x['severity']} | {esc(x['found_by'])} | {esc(x['detail'])[:260]} |")
            L.append("")
            if lim and len(rows) > lim:
                L += [f"_… {len(rows) - lim} more in report.json_", ""]
            if full:
                for x in rows:
                    if x.get("log_tail"):
                        L += [f"<details><summary><code>{x['pkg']}</code> build log tail</summary>",
                              "", "```", x["log_tail"], "```", "</details>", ""]

        L += [f"## 🗑️ Removal candidates ({len(removal)})", "",
              "Failing packages (build or sources) that no *working* BlackArch package hard-depends on.", ""]
        if removal:
            L += ["| Package | Problem | Produces | Verdict | Needed by |", "|---|---|---|---|---|"]
            for x in removal[:lim]:
                L.append(f"| `{x['pkg']}` | {x['problem']} | {', '.join(x['produces'])} | {esc(x['verdict'])} "
                         f"| {esc(x['needed_by'])} |")
        L.append("")

        L += [f"## 🐍 Python 2 packages that nothing hard-depends on ({len(py2)})", "",
              "No depends/makedepends/checkdepends on them anywhere in the tree "
              "(split packages are checked one by one).", ""]
        if py2:
            L += ["| Package | From PKGBUILD | Also builds | Latest build | optdepends of | Suggested action |",
                  "|---|---|---|---|---|---|"]
            for x in py2[:lim]:
                L.append(f"| `{x['name']}` | {x['dir']} | {', '.join(x['also_builds']) or '—'} | {x['build']} "
                         f"| {', '.join(x['optdepends_of']) or '—'} | {x['action']} |")
        L.append("")
        if lim and len(py2) > lim:
            L += [f"_… {len(py2) - lim} more in report.json_", ""]

        L += [f"## ✅ Updated ({len(ok)})", ""]
        if ok:
            L += ["| Package | From | To | Released |", "|---|---|---|---|"]
            for r in ok[:lim]:
                state = "yes" if r["pkg"] in published else (
                    ("in PR" if publish.get("pr_url") else "committed") if r["pkg"] in committed else "no")
                L.append(f"| `{r['pkg']}` | {esc(r['cur'])} | {esc(r.get('pkgver') or r['target'])} | {state} |")
        L.append("")
        if publish.get("skipped"):
            L += ["**Not published:** " + "; ".join(publish["skipped"]), ""]
        if warnings:
            wc = Counter(w["check"] for w in warnings)
            L += [f"<details><summary>Upstream-check warnings ({len(warnings)})</summary>", ""]
            L += [f"- {k}: {v}" for k, v in wc.most_common()]
            if full:
                L += ["", "| Package | Check | Message |", "|---|---|---|"]
                L += [f"| `{w['pkg']}` | {w['check']} | {esc(w['message'])[:250]} |" for w in warnings]
            L += ["</details>", ""]
        L += [f"<details><summary>Packages not tracked upstream ({len(untracked)}) — "
              "add entries to .github/ci/nvchecker-overrides.toml</summary>", ""]
        L += [f"- {r}: {n}" for r, n in Counter(untracked.values()).most_common(25)]
        L += ["</details>", ""]
        return "\n".join(L)

    (out / "report.md").write_text(md(True))
    issue = md(False)
    if len(issue) > 60000:
        issue = issue[:59000] + "\n\n… truncated, see the report artifact.\n"
    (out / "issue.md").write_text(issue)

    cutoff = now - dt.timedelta(days=60)
    seen = {k: v for k, v in seen.items() if dt.datetime.fromisoformat(v["date"]) > cutoff}
    Path(a.seen_out).write_text(json.dumps({"packages": seen, "builds": builds},
                                           indent=1, sort_keys=True))
    print(json.dumps(totals))


if __name__ == "__main__":
    main()
