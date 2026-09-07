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

# SparkApplication object names are "it-spark-pi-{suffix}-{ts_nodash}" - ts_nodash comes from
# `spark/spark_pi.yaml`'s own `{{ ts_nodash | lower }}`, rendered by Airflow's standard templating
# of application_file (application_file is a real templated_field with template_ext including
# "yaml", so its content gets the full per-task Jinja context, confirmed against the installed
# provider's source - not a DAG-parse-time uuid). ts_nodash derives from the dag run's
# logical_date, so every task in one run renders the identical value - `application_name` below
# uses the exact same expression so wait_local/wait_remote poll for the object that was actually
# created, not a name only one task's own Python process ever knew about (confirmed locally: a
# module-level `uuid.uuid4()` looked deterministic but is independently re-evaluated in every
# task's own pod, since each task re-imports this file from scratch - so submit_local and
# wait_local silently disagreed on the name almost every run).
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
    # and unique per dag run via ts_nodash, that extra suffix only breaks wait_*'s ability to know
    # the real name ahead of time.
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
        application_name="it-spark-pi-local-{{ ts_nodash | lower }}",
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
        application_name="it-spark-pi-remote-{{ ts_nodash | lower }}",
        kubernetes_conn_id="k8s_remote",
    )

    submit_local >> wait_local
    submit_remote >> wait_remote
