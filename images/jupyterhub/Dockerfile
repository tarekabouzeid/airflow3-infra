# Custom JupyterHub hub image.
#
# Extends the upstream zero-to-jupyterhub hub image with two additions:
#
#   kubectl — jupyterhub-multicluster-kubespawner invokes kubectl as a subprocess (rather than
#   using the Python kubernetes client) to create per-user Namespace/Pod/Service/Ingress objects
#   in the target cluster. The base image does not include kubectl.
#
#   jupyterhub-multicluster-kubespawner — the spawner that drives cross-cluster notebook
#   creation. Pinned via MULTICLUSTER_SPAWNER_VERSION in versions.env (rule 1).
#
# Build args match versions.env entries so CI can pass them from there. The KUBECTL version is
# pinned to the same patch level as the KIND node images in kind/*.yaml (KIND_NODE_IMAGE) so the
# client and server API versions stay in lock-step.

ARG HUB_IMAGE_TAG=3.3.8
FROM quay.io/jupyterhub/k8s-hub:${HUB_IMAGE_TAG}

USER root

ARG KUBECTL_VERSION=v1.32.8
RUN set -eux; \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl; \
    chmod +x /usr/local/bin/kubectl; \
    kubectl version --client

ARG MULTICLUSTER_SPAWNER_VERSION=0.2.0
RUN pip install --no-cache-dir \
    "jupyterhub-multicluster-kubespawner==${MULTICLUSTER_SPAWNER_VERSION}"

USER 1000
