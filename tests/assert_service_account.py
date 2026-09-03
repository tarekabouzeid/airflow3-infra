"""Fails loudly if a rendered Airflow pod template's serviceAccountName isn't derived from the
platform-controlled ServiceAccount prefix. Used by .github/workflows/lint.yaml against
/tmp/render-airflow.yaml.

The official chart treats serviceAccount.name as a PREFIX, not a literal name - it suffixes it
per component (e.g. "tenant-a-airflow" -> "tenant-a-airflow-scheduler"). Confirmed by an earlier
CI run; do not "fix" this check back to an exact-match without re-confirming against a real
render first.
"""
import sys

import yaml

SA_PREFIX = "tenant-a-airflow"
RENDERED_FILE = "/tmp/render-airflow.yaml"


def main(component: str) -> int:
    docs = list(yaml.safe_load_all(open(RENDERED_FILE)))
    found = False
    for d in docs:
        if not d:
            continue
        labels = (d.get("spec", {}) or {}).get("template", {}).get("metadata", {}).get("labels", {}) or {}
        if labels.get("component") == component:
            found = True
            sa = d["spec"]["template"]["spec"].get("serviceAccountName")
            if not sa or not sa.startswith(SA_PREFIX):
                print(
                    f"::error::{component} pod spec has serviceAccountName={sa!r}, expected it to "
                    f"start with {SA_PREFIX!r} - the airflow-tenant chart's serviceAccount override "
                    "key may be wrong, see charts/airflow-tenant/values.yaml"
                )
                return 1
    if not found:
        print(f"::warning::no rendered pod template found with component={component} - verify the chart's label convention")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
