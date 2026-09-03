"""Lightweight integration test: SparkKubernetesOperator (Kubeflow Spark Operator), run once
locally and once against a remote cluster. Submits spark-pi via spark/spark_pi.yaml and waits for
completion with SparkKubernetesSensor.

NOTE: SparkKubernetesOperator's exact constructor arguments have changed across
apache-airflow-providers-cncf-kubernetes releases. This DAG is verified against the pinned
provider version by e2e-kind.yaml, which actually submits and waits for both SparkApplications -
treat a CI failure here as this file needing an update for the current provider API, not a flake.
"""
from datetime import datetime

from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import SparkKubernetesOperator
from airflow.providers.cncf.kubernetes.sensors.spark_kubernetes import SparkKubernetesSensor

TENANT = "tenant-ci"
NAMESPACE = f"{TENANT}-workloads"
SERVICE_ACCOUNT = f"{TENANT}-workload-runner"

with DAG(
    dag_id="it_spark",
    description="Integration test: SparkKubernetesOperator, local + remote cluster",
    schedule=None,
    catchup=False,
    max_active_runs=1,
    start_date=datetime(2025, 1, 1),
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
        in_cluster=True,
    )
    wait_local = SparkKubernetesSensor(
        task_id="wait_local",
        namespace=NAMESPACE,
        application_name="{{ task_instance.xcom_pull(task_ids='submit_local')['metadata']['name'] }}",
        in_cluster=True,
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
