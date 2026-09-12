#!/usr/bin/env python3
"""Validate rendered manifests against the openAPIV3Schema of real upstream CRDs.

kubeconform is the right tool for core Kubernetes kinds, but every object this platform's
governance layer renders - ClusterQueue, LocalQueue, Cohort, ResourceFlavor, ClusterPolicy - is
CRD-backed, and `kubeconform -ignore-missing-schemas` waves those through entirely unchecked.
That is exactly where a misspelled or moved field hides: `helm template` is happy, kubeconform is
happy, and the API server rejects it on first sync.

Concrete things this catches that nothing else here does:
  - ResourceFlavor rendering a bare `spec:` (parsed as null) when the flavor has no node labels
    or taints, which the CRD rejects with "spec: None is not of type object".
  - Kueue v1beta2 renaming ClusterQueue's `spec.cohort` to `spec.cohortName`. The old spelling is
    not an error, it is simply ignored - leaving every queue in a cohort of one and silently
    disabling all borrowing, which is the entire mechanism the low-priority lane runs on.

Usage: validate_against_crds.py '<crd-glob>' <manifest> [<manifest> ...]
"""
import glob
import re
import sys

import jsonschema
import yaml

# OpenAPI extensions and annotations that a plain Draft-7 validator does not understand. Dropping
# `default` matters as well as the x-kubernetes-* keys: Draft-7 treats it as an assertion-free
# annotation, but leaving it in alongside `enum` produces confusing errors.
STRIP = {
    "x-kubernetes-preserve-unknown-fields", "x-kubernetes-int-or-string",
    "x-kubernetes-list-type", "x-kubernetes-list-map-keys", "x-kubernetes-map-type",
    "x-kubernetes-validations", "description", "default",
}


def load_crd_schemas(pattern):
    schemas = {}
    for path in sorted(glob.glob(pattern)):
        text = open(path).read()
        # CRDs vendored from a Helm chart's templates/ carry Go template actions. Strip the
        # leading {{- /* ... */}} comment block, then drop any remaining templated line.
        text = re.sub(r"\{\{-?\s*/\*.*?\*/\s*-?\}\}", "", text, flags=re.S)
        text = "\n".join(line for line in text.split("\n") if "{{" not in line)
        try:
            doc = yaml.safe_load(text)
        except yaml.YAMLError as exc:
            print(f"  ! skipping unparseable {path}: {exc}", file=sys.stderr)
            continue
        if not doc or doc.get("kind") != "CustomResourceDefinition":
            continue
        group, kind = doc["spec"]["group"], doc["spec"]["names"]["kind"]
        for version in doc["spec"]["versions"]:
            schema = version.get("schema", {}).get("openAPIV3Schema")
            if schema:
                schemas[f"{group}/{version['name']}:{kind}"] = schema
    return schemas


def sanitize(node):
    if isinstance(node, dict):
        return {k: sanitize(v) for k, v in node.items() if k not in STRIP}
    if isinstance(node, list):
        return [sanitize(v) for v in node]
    return node


def main():
    pattern, manifests = sys.argv[1], sys.argv[2:]
    schemas = load_crd_schemas(pattern)
    if not schemas:
        sys.exit(f"no CRD schemas loaded from {pattern!r} - the validation would prove nothing")
    print(f"loaded {len(schemas)} CRD schemas")

    checked = failures = 0
    skipped = set()
    for manifest in manifests:
        for doc in yaml.safe_load_all(open(manifest)):
            if not doc:
                continue
            key = f"{doc['apiVersion']}:{doc['kind']}"
            if key not in schemas:
                skipped.add(key)
                continue
            checked += 1
            try:
                jsonschema.Draft7Validator(sanitize(schemas[key])).validate(doc)
            except jsonschema.ValidationError as exc:
                failures += 1
                path = ".".join(str(p) for p in exc.absolute_path) or "<root>"
                print(f"FAIL {doc['kind']}/{doc['metadata']['name']} ({manifest})\n"
                      f"  path: {path}\n  {exc.message}", file=sys.stderr)

    print(f"validated {checked} CRD-backed objects, {failures} failure(s)")
    if skipped:
        print(f"not CRD-backed, left to kubeconform: {', '.join(sorted(skipped))}")
    if checked == 0:
        sys.exit("no CRD-backed objects found in the given manifests - check the render steps")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
