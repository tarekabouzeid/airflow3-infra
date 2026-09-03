# Adds the two providers not bundled in the base image:
#  - apache-airflow-providers-hashicorp: the Vault secrets backend (Connections/Variables from
#    Vault directly - see docs/architecture.md).
#  - apache-airflow-providers-cncf-kubernetes: KubernetesPodOperator + SparkKubernetesOperator.
#    Normally already bundled with the base image; pinned explicitly here via requirements.txt +
#    Airflow's own constraints file so the exact resolved version is always known.
ARG AIRFLOW_VERSION=3.1.7
FROM apache/airflow:${AIRFLOW_VERSION}

USER airflow
WORKDIR /opt/airflow

COPY requirements.txt /tmp/requirements.txt

# Use Airflow's own published constraints for this exact Airflow + Python version, exactly as
# https://airflow.apache.org/docs/apache-airflow/stable/installation/installing-from-pypi.html
# recommends - this is what keeps provider versions compatible with Airflow core, so we do not
# pin provider versions by hand in requirements.txt.
RUN PYTHON_VERSION=$(python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')") && \
    pip install --no-cache-dir \
      --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt" \
      -r /tmp/requirements.txt
