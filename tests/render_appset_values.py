#!/usr/bin/env python3
"""Resolve an ApplicationSet's goTemplate `helm.values` against the real tenant registry.

ApplicationSet templates are the one part of this repo that `helm template` cannot check:
until Argo CD renders them against a live registry entry they are just strings, so a typo in
`{{.kueue.nominal.cpu}}` or a key missing from one of the four workloads-*.yaml files stays
invisible until it reaches a cluster. This reproduces the git `files` generator plus goTemplate
substitution well enough to catch exactly those two failures, and emits values files that CI then
feeds to `helm template` for real.

Deliberately NOT a general Go template engine: it handles the `{{.dotted.path}}` substitution
this repo's ApplicationSets actually use and fails loudly on anything else, which matches
goTemplateOptions: ["missingkey=error"] rather than silently rendering "<no value>".

Usage: render_appset_values.py <appset.yaml> <output-dir>
"""
import glob
import os
import re
import sys

import yaml

PLACEHOLDER = re.compile(r"\{\{\s*\.([A-Za-z0-9_.]+)\s*\}\}")


def lookup(data, dotted, source):
    node = data
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(
                f"{source}: ApplicationSet references {{{{.{dotted}}}}} but that key does not "
                f"exist in this registry file. With goTemplateOptions missingkey=error this "
                f"fails the ApplicationSet at render time, not at apply time."
            )
        node = node[part]
    return node


def substitute(template, data, source):
    def repl(match):
        value = lookup(data, match.group(1), source)
        if isinstance(value, (dict, list)):
            raise TypeError(
                f"{source}: {{{{.{match.group(1)}}}}} resolves to a {type(value).__name__}, "
                f"which cannot be interpolated into a string."
            )
        return "" if value is None else str(value)

    return PLACEHOLDER.sub(repl, template)


def main():
    appset_path, outdir = sys.argv[1], sys.argv[2]
    appset = yaml.safe_load(open(appset_path))
    if appset.get("kind") != "ApplicationSet":
        print(f"{appset_path}: not an ApplicationSet, skipping")
        return 0

    patterns = [
        f["path"]
        for gen in appset["spec"]["generators"]
        if "git" in gen
        for f in gen["git"].get("files", [])
    ]
    registry_files = sorted({p for pat in patterns for p in glob.glob(pat)})
    if not registry_files:
        print(f"{appset_path}: generator matched no registry files", file=sys.stderr)
        return 1

    spec = appset["spec"]["template"]["spec"]
    sources = spec.get("sources") or [spec["source"]]
    os.makedirs(outdir, exist_ok=True)
    written = 0

    for reg_path in registry_files:
        data = yaml.safe_load(open(reg_path))
        app_name = substitute(appset["spec"]["template"]["metadata"]["name"], data, reg_path)
        for index, source in enumerate(sources):
            values = (source.get("helm") or {}).get("values")
            if not values:
                continue
            resolved = substitute(values, data, reg_path)
            # Must still be valid YAML once the placeholders are gone - an unquoted value that
            # happens to start with a digit or contain a colon breaks here rather than in-cluster.
            try:
                yaml.safe_load(resolved)
            except yaml.YAMLError as exc:
                print(f"{reg_path} -> {app_name} source[{index}]: resolved values are not valid "
                      f"YAML:\n{exc}", file=sys.stderr)
                return 1
            path = os.path.join(outdir, f"{app_name}.source{index}.yaml")
            open(path, "w").write(resolved)
            print(f"{reg_path} -> {path}")
            written += 1

    if not written:
        print(f"{appset_path}: no helm.values blocks to resolve", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
