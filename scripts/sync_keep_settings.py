#!/usr/bin/env python3
"""Keep the pipeline settings a user edited when sync-from-github.yml resets
main to a new GitHub release.

The reset replaces azure-pipelines.yml and the federated pipeline with the
released versions. Three things in them are meant to be edited by the user
and would otherwise be lost on every sync:

  - the default of the productionApprovalEnvironment parameter
  - an uncommented schedules: block
  - the serviceConnection variable (federated pipeline)

Usage: sync_keep_settings.py <commit before the reset>
Rewrites the files in place and prints what it kept. Exit code 0 always
unless the arguments are wrong: a value it cannot find is left as released.
"""
import re
import subprocess
import sys

FILES = ["azure-pipelines.yml", "pipelines/azure-pipelines-federated.yml"]

PARAM_DEFAULT = re.compile(
    r"(- name: productionApprovalEnvironment\n(?:[ \t]+[^\n]*\n)*?[ \t]+default:[ \t]*)([^\n]*)")
SERVICE_CONNECTION = re.compile(r"(- name: serviceConnection\n[ \t]+value:[ \t]*)([^\n]*)")
# An active (uncommented) top-level schedules block: the key line plus every
# following indented, comment or blank line.
ACTIVE_SCHEDULES = re.compile(r"^schedules:[^\n]*\n(?:(?:[ \t]+[^\n]*|#[^\n]*|[ \t]*)\n)*", re.M)
COMMENTED_SCHEDULES = re.compile(r"^# schedules:[^\n]*\n(?:#[^\n]*\n)*", re.M)


def old_text(commit, path):
    try:
        return subprocess.run(["git", "show", f"{commit}:{path}"], check=True,
                              capture_output=True, text=True).stdout
    except subprocess.CalledProcessError:
        return None


def trim_block(block):
    # Do not carry trailing comment or blank lines that belong to the next key.
    lines = block.split("\n")
    while lines and (lines[-1].strip() == "" or lines[-1].startswith("#")):
        lines.pop()
    return "\n".join(lines) + "\n"


def keep(old, new):
    kept = []
    for rx, label in ((PARAM_DEFAULT, "productionApprovalEnvironment default"),
                      (SERVICE_CONNECTION, "serviceConnection")):
        o, n = rx.search(old), rx.search(new)
        if o and n and o.group(2).strip() != n.group(2).strip():
            new = new[:n.start(2)] + o.group(2) + new[n.end(2):]
            kept.append(f"{label}: {o.group(2).strip()}")

    o = ACTIVE_SCHEDULES.search(old)
    if o:
        block = trim_block(o.group(0))
        n = ACTIVE_SCHEDULES.search(new)
        if n:
            if trim_block(n.group(0)) != block:
                new = new[:n.start()] + block + new[n.start() + len(trim_block(n.group(0))):]
                kept.append("schedules")
        else:
            c = COMMENTED_SCHEDULES.search(new)
            if c:
                new = new[:c.start()] + block + new[c.end():]
            else:
                p = re.search(r"^pool:", new, re.M)
                at = p.start() if p else len(new)
                new = new[:at] + block + "\n" + new[at:]
            kept.append("schedules")
    return new, kept


def main():
    if len(sys.argv) != 2:
        print("usage: sync_keep_settings.py <commit before the reset>")
        return 2
    for path in FILES:
        old = old_text(sys.argv[1], path)
        if old is None:
            continue
        try:
            with open(path, encoding="utf-8") as f:
                new = f.read()
        except FileNotFoundError:
            continue
        result, kept = keep(old, new)
        if kept:
            with open(path, "w", encoding="utf-8") as f:
                f.write(result)
            print(f"{path}: kept {', '.join(kept)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
