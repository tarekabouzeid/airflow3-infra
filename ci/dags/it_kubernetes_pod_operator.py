"""Lightweight integration test: KubernetesPodOperator, run once locally and once against a
remote cluster (kubernetes_conn_id="k8s_remote", sourced from Vault via the Airflow secrets
backend - see docs/architecture.md). Both tasks read a value from the ESO-synced
"<tenant>-workload-secrets" Secret, which proves the full Vault -> ExternalSecret -> pod path in
both clusters with a single DAG run.
"""
from datetime import datetime, timezone

from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from kubernetes.client import models as k8s

TENANT = "tenant-ci"
NAMESPACE = f"{TENANT}-workloads"

SECRET_ENV = [
    k8s.V1EnvVar(
        name="GREETING",
        value_from=k8s.V1EnvVarSource(
            secret_key_ref=k8s.V1SecretKeySelector(name=f"{TENANT}-workload-secrets", key="greeting")
        ),
    )
]

with DAG(
    dag_id="it_kubernetes_pod_operator",
    description="Integration test: KubernetesPodOperator, local + remote cluster",
    schedule=None,
    catchup=False,
    max_active_runs=1,
    start_date=datetime(2025, 1, 1, tzinfo=timezone.utc),
    default_args={"retries": 0},
    tags=["integration-test", TENANT],
) as dag:
    local_pod = KubernetesPodOperator(
        task_id="local_pod",
        namespace=NAMESPACE,
        name="it-kpo-local",
        image="busybox:1.36",
        cmds=["sh", "-c"],
        arguments=["echo LOCAL: $GREETING"],
        env_vars=SECRET_ENV,
        in_cluster=True,
        is_delete_operator_pod=True,
        get_logs=True,
    )

    remote_pod = KubernetesPodOperator(
        task_id="remote_pod",
        namespace=NAMESPACE,
        name="it-kpo-remote",
        image="busybox:1.36",
        cmds=["sh", "-c"],
        arguments=["echo REMOTE: $GREETING"],
        env_vars=SECRET_ENV,
        kubernetes_conn_id="k8s_remote",
        is_delete_operator_pod=True,
        get_logs=True,
    )
