#!/usr/bin/env python3
"""Assert that Kueue's ceiling fits inside the namespace ResourceQuota.

Kueue and the API server police capacity independently: Kueue admits a Workload against its own
quota accounting, and the API server then applies the namespace ResourceQuota. Whichever is
tighter is what actually binds. If the ResourceQuota is the tighter one, Kueue admits work the
API server immediately rejects - pods stuck Pending with "exceeded quota" while `kubectl get
workloads` cheerfully reports them admitted. That failure is silent, it only shows up under load,
and it looks like a Kueue bug rather than a quota mis-sizing.

So the invariant is: for every (tenant, cluster),
    kueue.nominal + kueue.borrowingLimit  <=  workload namespace ResourceQuota requests

which keeps Kueue the operative limit and the ResourceQuota a backstop that only fires if
something has gone wrong elsewhere.

Reads the two files that actually carry these numbers, so it fails on a real edit rather than on
a copy of one: platform/tenants/*/workloads-*.yaml and the inline quota in
platform/bootstrap/appset-tenant-workloads.yaml.
"""
import glob
import re
import sys

import yaml

SUFFIXES = {
    "Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4,
    "k": 1000, "M": 1000**2, "G": 1000**3, "T": 1000**4,
}


def quantity(value):
    """Parse a Kubernetes quantity into a float. Handles the "100m" milli-suffix and binary/SI."""
    text = str(value).strip()
    if text.endswith("m") and not text.endswith("Mi"):
        return float(text[:-1]) / 1000
    match = re.fullmatch(r"([0-9.]+)([A-Za-z]*)", text)
    if not match:
        raise ValueError(f"cannot parse quantity {value!r}")
    number, suffix = match.groups()
    if not suffix:
        return float(number)
    if suffix not in SUFFIXES:
        raise ValueError(f"unknown quantity suffix in {value!r}")
    return float(number) * SUFFIXES[suffix]


def workload_namespace_quota():
    """The ResourceQuota the tenant-workloads ApplicationSet stamps on every workload namespace."""
    appset = yaml.safe_load(open("platform/bootstrap/appset-tenant-workloads.yaml"))
    for source in appset["spec"]["template"]["spec"]["sources"]:
        if not source.get("path", "").endswith("tenant-project"):
            continue
        # Strip the goTemplate placeholders; none of them appear inside the quota block, so a
        # crude blanking is enough to make the values parse as YAML.
        text = re.sub(r"\{\{[^}]*\}\}", "PLACEHOLDER", source["helm"]["values"])
        values = yaml.safe_load(text)
        if "quota" in values:
            return values["quota"]
    raise SystemExit(
        "appset-tenant-workloads.yaml no longer sets an inline `quota` for the tenant-project "
        "source. Either restore it or update this check - a workload namespace falling back to "
        "the chart default quota would silently become tighter than the Kueue ceiling."
    )


def main():
    quota = workload_namespace_quota()
    limits = {
        "cpu": quantity(quota["requests.cpu"]),
        "memory": quantity(quota["requests.memory"]),
        "pods": quantity(quota["pods"]),
    }

    failures = []
    for path in sorted(glob.glob("platform/tenants/*/workloads-*.yaml")):
        entry = yaml.safe_load(open(path))
        kueue = entry.get("kueue")
        if not kueue:
            failures.append(f"{path}: no `kueue` block - every workload registry entry needs one, "
                            f"or appset-tenant-queues fails with missingkey=error")
            continue
        for resource, limit in limits.items():
            nominal = quantity(kueue["nominal"][resource])
            borrow = quantity(kueue["borrowingLimit"][resource])
            ceiling = nominal + borrow
            status = "ok" if ceiling <= limit else "TOO HIGH"
            print(f"  {path} {resource:<7} nominal+borrow={ceiling:<12,.0f} "
                  f"namespace quota={limit:<12,.0f} {status}")
            if ceiling > limit:
                failures.append(
                    f"{path}: {resource} ceiling (nominal {kueue['nominal'][resource]} + "
                    f"borrowingLimit {kueue['borrowingLimit'][resource]}) exceeds the workload "
                    f"namespace ResourceQuota requests.{resource} "
                    f"({quota.get('requests.' + resource, quota.get(resource))}). Either lower "
                    f"the Kueue numbers or raise the quota in appset-tenant-workloads.yaml."
                )

    if failures:
        print("\nquota invariant violated:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("\nquota invariant holds for every (tenant, cluster).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
