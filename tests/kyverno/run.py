#!/usr/bin/env python3
"""Render the governance ClusterPolicies and assert every rule behaves as documented.

Run locally (needs helm and the kyverno CLI on PATH):
    python3 tests/kyverno/run.py

Three things this does that a bare `kyverno test` does not:

1. Renders the policies out of charts/cluster-governance with policy.action=Enforce and writes
   ONLY the ClusterPolicy documents. The CLI silently loads zero policies from a file that also
   contains other kinds - it prints "Applying 0 policy rule(s)" and exits 0, so a suite fed the
   raw helm output passes while testing nothing.

2. Forces Enforce regardless of the chart default. The chart ships Audit so a blind spot cannot
   brick a namespace on first sync; the assertions below are only unambiguous under Enforce, so
   this proves the Enforce behaviour ahead of anyone flipping that value.

3. Fails on a policy Kyverno REFUSED TO LOAD. `kyverno test` reports such a policy as
   "Skip / Invalid Policy" and still counts the assertion as passed - verified against this very
   suite by deleting the `images` list from a container-level PSS control exclusion, which makes
   the whole pod-security policy invalid and yet still reported 20/20 green. An invalid policy is
   an unenforced policy, and in Audit mode it is invisible: the PolicyReports are simply empty,
   which reads exactly like compliance.
"""
import json
import pathlib
import shutil
import subprocess
import sys

import yaml

HERE = pathlib.Path(__file__).parent
REPO = HERE.parent.parent
RENDERED = HERE / "rendered-policies.yaml"


def require(binary):
    path = shutil.which(binary)
    if not path:
        sys.exit(f"{binary} not found on PATH")
    return path


def render(helm):
    out = subprocess.run(
        [helm, "template", "cluster-governance", "charts/cluster-governance",
         "--set", "policy.action=Enforce"],
        cwd=REPO, check=True, capture_output=True, text=True,
    ).stdout
    policies = [d for d in yaml.safe_load_all(out) if d and d.get("kind") == "ClusterPolicy"]
    if not policies:
        sys.exit("charts/cluster-governance rendered no ClusterPolicy documents")
    with RENDERED.open("w") as handle:
        yaml.dump_all(policies, handle, sort_keys=False)
    print(f"rendered {len(policies)} ClusterPolicies (action=Enforce):")
    for policy in policies:
        rules = ", ".join(r["name"] for r in policy["spec"]["rules"])
        print(f"  {policy['metadata']['name']}: {rules}")
    return policies


def run_tests(kyverno):
    result = subprocess.run(
        [kyverno, "test", str(HERE), "-o", "json", "--remove-color"],
        cwd=REPO, capture_output=True, text=True,
    )
    stdout = result.stdout
    start = stdout.find("\n[")
    if start == -1:
        print(stdout)
        print(result.stderr, file=sys.stderr)
        sys.exit("kyverno test produced no JSON results")
    # The JSON array is sandwiched between a progress preamble and a human-readable summary, so
    # decode just the array and ignore whatever trails it.
    rows, _ = json.JSONDecoder().raw_decode(stdout[start:].lstrip())
    return rows, result.returncode


def main():
    helm, kyverno = require("helm"), require("kyverno")
    policies = render(helm)
    rows, code = run_tests(kyverno)

    invalid = [r for r in rows if r["REASON"] != "Ok"]
    failed = [r for r in rows if r["RESULT"] != "Pass"]

    for row in rows:
        mark = "ok  " if row["RESULT"] == "Pass" and row["REASON"] == "Ok" else "FAIL"
        print(f"  {mark} {row['POLICY']}/{row['RULE']} -> {row['RESOURCE']} "
              f"({row['RESULT']}, {row['REASON']})")

    if invalid:
        print("\nKyverno refused to load at least one policy - these assertions proved nothing:",
              file=sys.stderr)
        for row in invalid:
            print(f"  - {row['POLICY']}/{row['RULE']}: {row['REASON']}", file=sys.stderr)
        print("An invalid policy is an unenforced policy. Run `kyverno apply` on\n"
              f"{RENDERED} to see the validation error.", file=sys.stderr)
        return 1
    if failed or code != 0:
        print(f"\n{len(failed)} assertion(s) did not match the expected result.", file=sys.stderr)
        return 1

    # Guard against the suite quietly shrinking: every rule in every rendered policy should be
    # exercised, or a rule can be added with no test and nobody notices.
    tested = {(r["POLICY"], r["RULE"]) for r in rows}
    declared = {(p["metadata"]["name"], rule["name"])
                for p in policies for rule in p["spec"]["rules"]}
    untested = sorted(declared - tested)
    if untested:
        print("\nRules with no assertion in kyverno-test.yaml:", file=sys.stderr)
        for policy, rule in untested:
            print(f"  - {policy}/{rule}", file=sys.stderr)
        return 1

    print(f"\nAll {len(rows)} assertions passed; every rendered rule is covered.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
