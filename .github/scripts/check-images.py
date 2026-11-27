#!/usr/bin/env python3
"""Check that every image reference a pull request adds or changes exists in its registry.

Run from the root of a checkout of the PR merge commit (fetch-depth >= 2): the first
parent (HEAD^1) is the base branch. For each changed YAML file, the script collects the
image references in the base and the head versions, and checks only the references that
are new in the head. It reads manifests with `crane` and pulls no layers.

Image references it finds:
  - a mapping with `repository` + `tag` (app-template, most charts), with an optional
    `registry` and an optional separate `digest`; `tag` may be `tag@sha256:...`
  - a string value under an `image` key (plain manifests, some charts)

Per reference it fails on: a digest that does not exist, a tag that does not exist, and a
tag that no longer points at the pinned digest (and has no platform manifest with it).
It warns (does not fail) on a reference with no digest and on the `latest` tag.

Needs: python3 (stdlib only), git, yq (mikefarah, preinstalled on GitHub runners), crane.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

BASE = os.environ.get("BASE_REF", "HEAD^1")
HEAD = "HEAD"
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
REF_RE = re.compile(r"^[a-z0-9][a-z0-9._/:@-]*$", re.IGNORECASE)
# Errors that mean "this does not exist" - do not retry those.
PERMANENT = ("MANIFEST_UNKNOWN", "NAME_UNKNOWN", "NOT_FOUND", "404", "UNAUTHORIZED", "DENIED", "401", "403")


def run(cmd: list[str], stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True)


def changed_files() -> list[str]:
    out = run(["git", "diff", "--name-only", "--diff-filter=AMR", BASE, HEAD])
    if out.returncode != 0:
        sys.exit(f"git diff failed: {out.stderr.strip()}")
    return [
        f
        for f in out.stdout.splitlines()
        if f.endswith((".yaml", ".yml")) and not f.endswith((".sops.yaml", ".sops.yml"))
    ]


def load_docs(text: str) -> list | None:
    """Parse a (multi-document) YAML string to JSON objects with yq. None if it is not YAML."""
    if not text.strip():
        return []
    out = run(["yq", "-o=json", "-I=0", "."], stdin=text)
    if out.returncode != 0:
        return None
    docs = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if line:
            docs.append(json.loads(line))
    return docs


def scalar(v) -> str | None:
    if isinstance(v, str):
        return v.strip() or None
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return str(v)
    return None


def plausible(ref: str) -> bool:
    return "{{" not in ref and "$" not in ref and REF_RE.match(ref) is not None and ("/" in ref or ":" in ref or "@" in ref)


def collect(node, found: set[str]) -> None:
    if isinstance(node, dict):
        repo, tag = scalar(node.get("repository")), scalar(node.get("tag"))
        if repo and tag and "://" not in repo:
            registry, digest = scalar(node.get("registry")), scalar(node.get("digest"))
            name = f"{registry}/{repo}" if registry and not repo.startswith(registry + "/") else repo
            ref = f"{name}:{tag}"
            if digest and "@" not in tag:
                ref += f"@{digest}"
            if plausible(ref):
                found.add(ref)
        image = node.get("image")
        if isinstance(image, str) and plausible(image.strip()):
            found.add(image.strip())
        for v in node.values():
            collect(v, found)
    elif isinstance(node, list):
        for v in node:
            collect(v, found)


def refs_in(text: str) -> set[str] | None:
    docs = load_docs(text)
    if docs is None:
        return None
    found: set[str] = set()
    for d in docs:
        collect(d, found)
    return found


def split_ref(ref: str) -> tuple[str, str | None, str | None]:
    digest = None
    if "@" in ref:
        ref, digest = ref.split("@", 1)
    name, tag = ref, None
    if ":" in ref.rsplit("/", 1)[-1]:
        name, tag = ref.rsplit(":", 1)
    return name, tag, digest


def crane(*args: str) -> tuple[bool, str]:
    """Run crane with retries on transient errors. Returns (ok, stdout-or-error)."""
    err = ""
    for attempt in range(3):
        out = run(["crane", *args])
        if out.returncode == 0:
            return True, out.stdout.strip()
        err = (out.stderr.strip().splitlines() or ["unknown error"])[-1]
        if any(p in err for p in PERMANENT):
            break
        time.sleep(2 * (attempt + 1))
    return False, err


def check(ref: str) -> tuple[list[str], list[str]]:
    errors, warnings = [], []
    name, tag, digest = split_ref(ref)
    if digest and not DIGEST_RE.match(digest):
        return [f"`{digest}` is not a valid sha256 digest"], []
    if digest:
        ok, msg = crane("digest", f"{name}@{digest}")
        if not ok:
            errors.append(f"digest `{digest}` does not exist in `{name}` ({msg})")
    if tag:
        ok, tag_digest = crane("digest", f"{name}:{tag}")
        if not ok:
            errors.append(f"tag `{tag}` does not exist in `{name}` ({tag_digest})")
        elif digest and tag_digest != digest and not errors:
            ok, manifest = crane("manifest", f"{name}:{tag}")
            children = []
            if ok:
                try:
                    children = [m.get("digest") for m in json.loads(manifest).get("manifests", [])]
                except (ValueError, AttributeError):
                    children = []
            if digest not in children:
                errors.append(
                    f"tag `{tag}` points at `{tag_digest}`, not at the pinned `{digest}` "
                    "(copy the digest of this tag, or fix the tag)"
                )
        if tag == "latest":
            warnings.append("uses the `latest` tag; pin a version tag (house rule)")
    if not digest:
        warnings.append("has no digest; pin it as `tag@sha256:...` (house rule)")
    return errors, warnings


def main() -> int:
    new: dict[str, set[str]] = {}
    for f in changed_files():
        head_text = open(f, encoding="utf-8").read()
        base = run(["git", "show", f"{BASE}:{f}"])
        base_text = base.stdout if base.returncode == 0 else ""
        head_refs, base_refs = refs_in(head_text), refs_in(base_text)
        if head_refs is None:
            print(f"skip {f}: not plain YAML (template?)")
            continue
        for ref in head_refs - (base_refs or set()):
            new.setdefault(ref, set()).add(f)

    summary = ["## Image check", ""]
    if not new:
        print("No new or changed image references.")
        summary.append("No new or changed image references in this pull request.")
        write_summary(summary)
        return 0

    failed = 0
    summary += ["| Result | Image | File | Detail |", "| --- | --- | --- | --- |"]
    for ref in sorted(new):
        errors, warnings = check(ref)
        files = sorted(new[ref])
        where = ", ".join(f"`{f}`" for f in files)
        if errors:
            failed += 1
            for e in errors:
                for f in files:
                    print(f"::error file={f},title=Image check::{ref}: {strip_md(e)}")
            summary.append(f"| FAIL | `{ref}` | {where} | {'; '.join(errors)} |")
        else:
            summary.append(f"| ok | `{ref}` | {where} | {'; '.join(warnings) or 'tag and digest exist'} |")
        for w in warnings:
            for f in files:
                print(f"::warning file={f},title=Image check::{ref}: {strip_md(w)}")
        if not errors:
            print(f"ok   {ref}")

    summary += ["", f"{len(new)} image reference(s) checked, {failed} failed."]
    write_summary(summary)
    if failed:
        print(f"\n{failed} image reference(s) failed the check. See the errors above.")
        return 1
    return 0


def strip_md(s: str) -> str:
    return s.replace("`", "")


def write_summary(lines: list[str]) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
