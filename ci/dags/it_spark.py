"""Lightweight integration test: SparkKubernetesOperator (Kubeflow Spark Operator), run once
locally and once against a remote cluster. Submits spark-pi via spark/spark_pi.yaml and waits for
completion with SparkKubernetesSensor.

NOTE: unlike KubernetesPodOperator, neither SparkKubernetesOperator nor SparkKubernetesSensor
accepts an `in_cluster` kwarg directly - only `kubernetes_conn_id` (default "kubernetes_default").
For the local tasks we deliberately pass no connection at all: KubernetesHook's own fallback for
the literal "kubernetes_default" conn id is an empty Connection, which resolves to in-cluster
config automatically (verified against the installed provider's source, not assumed).
"""
import uuid
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

# Computed once at DAG-parse time, in plain Python - not a Jinja macro like {{ ts_nodash }}.
# operators/spark_kubernetes.py's own SparkApplication-name rendering context only has `params`
# in scope, not the full task Jinja context (confirmed locally: {{ ts_nodash }} in the template
# raised UndefinedError there, even though it renders fine elsewhere). A params dict VALUE that
# itself contains {{ ... }} is also not re-rendered - it lands in the k8s object name literally,
# which then gets rejected (only alphanumeric/dashes/dots/underscores allowed).
_RUN_SUFFIX = uuid.uuid4().hex[:8]
LOCAL_APP_NAME = f"it-spark-pi-local-{_RUN_SUFFIX}"
REMOTE_APP_NAME = f"it-spark-pi-remote-{_RUN_SUFFIX}"

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
    # already fully deterministic from LOCAL_APP_NAME/REMOTE_APP_NAME above, so there's no need to
    # recover it via XCom at all.
    #
    # delete_on_termination=False (default is True): SparkKubernetesOperator deletes the
    # SparkApplication object itself the moment the job finishes. wait_local/wait_remote poll that
    # same object afterward - with the default, they lose the race and 404 (confirmed locally:
    # submit_* succeeding and the SparkApplication completing is not enough, the object has to
    # still exist by the time the downstream sensor's own pod gets scheduled a few seconds later).
    submit_local = SparkKubernetesOperator(
        task_id="submit_local",
        namespace=NAMESPACE,
        application_file="spark/spark_pi.yaml",
        params={"namespace": NAMESPACE, "service_account": SERVICE_ACCOUNT, "suffix": f"local-{_RUN_SUFFIX}"},
        delete_on_termination=False,
    )
    wait_local = SparkKubernetesSensor(
        task_id="wait_local",
        namespace=NAMESPACE,
        application_name=LOCAL_APP_NAME,
    )

    submit_remote = SparkKubernetesOperator(
        task_id="submit_remote",
        namespace=NAMESPACE,
        application_file="spark/spark_pi.yaml",
        params={"namespace": NAMESPACE, "service_account": SERVICE_ACCOUNT, "suffix": f"remote-{_RUN_SUFFIX}"},
        delete_on_termination=False,
        kubernetes_conn_id="k8s_remote",
    )
    wait_remote = SparkKubernetesSensor(
        task_id="wait_remote",
        namespace=NAMESPACE,
        application_name=REMOTE_APP_NAME,
        kubernetes_conn_id="k8s_remote",
    )

    submit_local >> wait_local
    submit_remote >> wait_remote
