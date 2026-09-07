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

# SparkApplication object names are "it-spark-pi-{suffix}-{sanitized run_id}". run_id (not
# ts_nodash/ds/ts) is the only per-run identifier guaranteed present: get_template_context()
# (airflow.sdk.execution_time.task_runner) only adds ts_nodash and friends when
# dag_run.logical_date is truthy, and a schedule=None DAG triggered without an explicit logical
# date gets logical_date=None in Airflow 3 - confirmed locally, {{ ts_nodash }} raised
# "UndefinedError: 'ts_nodash' is undefined" here for exactly that reason. run_id is sanitized
# (colons/plus/dots/underscores -> '-', lowercased) because Airflow's own default manual run_id
# ("manual__2026-01-01T00:00:00+00:00") isn't a valid Kubernetes object name otherwise. This
# expression is duplicated verbatim in spark/spark_pi.yaml's `name:` field (rendered there via
# application_file, a real templated_field with template_ext including "yaml" - confirmed against
# the installed provider's source) and in application_name below, so wait_local/wait_remote poll
# for the exact object submit_local/submit_remote actually created. A module-level
# `uuid.uuid4()` was tried first and looked deterministic but is independently re-evaluated in
# every task's own pod (each task re-imports this file from scratch), so submit_local and
# wait_local silently disagreed on the name almost every run - run_id/ts_nodash-style values work
# because Airflow computes them once per dag run and injects the same value into every task's
# context, not because they're computed in this file.
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
    # do_xcom_push deliberately omitted (defaults to False): per the operator's own docstring, it
    # means "read /airflow/xcom/return.json from inside the pod via a sidecar container" - the
    # same KubernetesPodOperator mechanism this operator's execute() delegates to. The Spark
    # driver pod is built entirely by the Spark Operator, not Airflow, so it never gets that
    # sidecar - do_xcom_push=True here just waits forever for a container that will never start
    # (confirmed locally: the SparkApplication itself completed successfully in 13s, while the
    # Airflow task sat "running" for 25+ minutes waiting on the sidecar). The application name is
    # already fully deterministic (see module docstring above), so there's no need to recover it
    # via XCom at all.
    #
    # random_name_suffix=False: SparkKubernetesOperator's own create_job_name() appends 8 more
    # random characters onto metadata.name by default - with the object name already deterministic
    # and unique per dag run via run_id (see module docstring above), that extra suffix only
    # breaks wait_*'s ability to know the real name ahead of time.
    #
    # delete_on_termination=False (default is True): SparkKubernetesOperator deletes the
    # SparkApplication object itself the moment the job finishes, which would otherwise race the
    # downstream sensor's own pod-scheduling latency.
    submit_local = SparkKubernetesOperator(
        task_id="submit_local",
        namespace=NAMESPACE,
        application_file="spark/spark_pi.yaml",
        params={"namespace": NAMESPACE, "service_account": SERVICE_ACCOUNT, "suffix": "local"},
        delete_on_termination=False,
        random_name_suffix=False,
    )
    wait_local = SparkKubernetesSensor(
        task_id="wait_local",
        namespace=NAMESPACE,
        application_name="it-spark-pi-local-{{ run_id | replace(':', '-') | replace('+', '-') | replace('.', '-') | replace('_', '-') | lower }}",
    )

    submit_remote = SparkKubernetesOperator(
        task_id="submit_remote",
        namespace=NAMESPACE,
        application_file="spark/spark_pi.yaml",
        params={"namespace": NAMESPACE, "service_account": SERVICE_ACCOUNT, "suffix": "remote"},
        delete_on_termination=False,
        random_name_suffix=False,
        kubernetes_conn_id="k8s_remote",
    )
    wait_remote = SparkKubernetesSensor(
        task_id="wait_remote",
        namespace=NAMESPACE,
        application_name="it-spark-pi-remote-{{ run_id | replace(':', '-') | replace('+', '-') | replace('.', '-') | replace('_', '-') | lower }}",
        kubernetes_conn_id="k8s_remote",
    )

    submit_local >> wait_local
    submit_remote >> wait_remote
