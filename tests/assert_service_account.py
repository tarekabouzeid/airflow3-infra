"""Fails loudly if a rendered Airflow pod template's serviceAccountName doesn't match the
platform-controlled value. Used by .github/workflows/lint.yaml against /tmp/render-airflow.yaml.
"""
import sys

import yaml

EXPECTED_SA = "tenant-a-airflow"
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
            if sa != EXPECTED_SA:
                print(
                    f"::error::{component} pod spec has serviceAccountName={sa!r}, expected "
                    f"{EXPECTED_SA!r} - the airflow-tenant chart's serviceAccount override key "
                    "may be wrong, see charts/airflow-tenant/values.yaml"
                )
                return 1
    if not found:
        print(f"::warning::no rendered pod template found with component={component} - verify the chart's label convention")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
