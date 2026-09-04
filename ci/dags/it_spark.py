"""Lightweight integration test: SparkKubernetesOperator (Kubeflow Spark Operator), run once
locally and once against a remote cluster. Submits spark-pi via spark/spark_pi.yaml and waits for
completion with SparkKubernetesSensor.

NOTE: unlike KubernetesPodOperator, neither SparkKubernetesOperator nor SparkKubernetesSensor
accepts an `in_cluster` kwarg directly - only `kubernetes_conn_id` (default "kubernetes_default").
For the local tasks we deliberately pass no connection at all: KubernetesHook's own fallback for
the literal "kubernetes_default" conn id is an empty Connection, which resolves to in-cluster
config automatically (verified against the installed provider's source, not assumed).
"""
from datetime import datetime, timezone

from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import (
    SparkKubernetesOperator,
)
from airflow.providers.cncf.kubernetes.sensors.spark_kubernetes import (
    SparkKubernetesSensor,
)

TENANT = "tenant-ci"
NAMESPACE = f"{TENANT}-workloads"
SERVICE_ACCOUNT = f"{TENANT}-workload-runner"

with DAG(
    dag_id="it_spark",
    description="Integration test: SparkKubernetesOperator, local + remote cluster",
    schedule=None,
    catchup=False,
    max_active_runs=1,
    start_date=datetime(2025, 1, 1, tzinfo=timezone.utc),
    default_args={"retries": 0},
    tags=["integration-test", TENANT],
    params={"namespace": NAMESPACE, "service_account": SERVICE_ACCOUNT},
) as dag:
    submit_local = SparkKubernetesOperator(
        task_id="submit_local",
        namespace=NAMESPACE,
        application_file="spark/spark_pi.yaml",
        params={"namespace": NAMESPACE, "service_account": SERVICE_ACCOUNT, "suffix": "local-{{ ts_nodash | lower }}"},
        do_xcom_push=True,
    )
    wait_local = SparkKubernetesSensor(
        task_id="wait_local",
        namespace=NAMESPACE,
        application_name="{{ task_instance.xcom_pull(task_ids='submit_local')['metadata']['name'] }}",
    )

    submit_remote = SparkKubernetesOperator(
        task_id="submit_remote",
        namespace=NAMESPACE,
        application_file="spark/spark_pi.yaml",
        params={"namespace": NAMESPACE, "service_account": SERVICE_ACCOUNT, "suffix": "remote-{{ ts_nodash | lower }}"},
        do_xcom_push=True,
        kubernetes_conn_id="k8s_remote",
    )
    wait_remote = SparkKubernetesSensor(
        task_id="wait_remote",
        namespace=NAMESPACE,
        application_name="{{ task_instance.xcom_pull(task_ids='submit_remote')['metadata']['name'] }}",
        kubernetes_conn_id="k8s_remote",
    )

    submit_local >> wait_local
    submit_remote >> wait_remote
