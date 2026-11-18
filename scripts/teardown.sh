#!/usr/bin/env bash
# Removes everything the lab created: the kind cluster "infergw" (and with it
# every namespace, CRD and Helm release in it) and the
# lab's kubeconfig. Nothing else on the machine is touched.
# Exits non-zero if the cluster or one of its node containers is still there.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "kind cluster ${CLUSTER_NAME}"
# On a loaded Docker Desktop a node container can take longer to exit than
# docker rm waits ("did not receive an exit event"); it exits a few seconds
# later, so try again before reporting leftovers.
for attempt in 1 2 3; do
  kind delete cluster --name "${CLUSTER_NAME}" && break
  note "kind delete failed (attempt ${attempt}); retrying in 10s"
  sleep 10
done
rm -f "${KUBECONFIG}"

step "leftovers"
expect_eq "kind cluster ${CLUSTER_NAME} gone" "" "$(kind get clusters 2>/dev/null | grep -x "${CLUSTER_NAME}" || true)"
expect_eq "no node containers left" "0" "$(docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" -q | wc -l | tr -d ' ')"
finish
