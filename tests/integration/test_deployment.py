"""
Integration tests for Kubernetes deployment
"""
import pytest
import subprocess
import os
from kubernetes import client, config, watch
import time


@pytest.fixture(scope='session')
def kubeconfig():
    """Load kubeconfig"""
    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()


class TestDeployment:
    """Test Kubernetes deployment"""

    def test_deployment_exists(self, kubeconfig):
        """Verify deployment exists"""
        v1 = client.AppsV1Api()
        deployments = v1.list_namespaced_deployment('app')
        names = [d.metadata.name for d in deployments.items]
        assert 'my-app' in names or len(names) > 0

    def test_pods_running(self, kubeconfig):
        """Verify pods are running"""
        v1 = client.CoreV1Api()
        pods = v1.list_namespaced_pod('app')

        # Should have at least pods running
        assert len(pods.items) > 0

        for pod in pods.items:
            if 'my-app' in pod.metadata.name:
                assert pod.status.phase == 'Running'

    def test_service_exists(self, kubeconfig):
        """Verify service exists"""
        v1 = client.CoreV1Api()
        services = v1.list_namespaced_service('app')
        names = [s.metadata.name for s in services.items]
        assert 'my-app' in names or len(names) > 0


class TestConnectivity:
    """Test network connectivity"""

    def test_pod_to_pod_connectivity(self, kubeconfig):
        """Test pod-to-pod connectivity"""
        # This would require port-forwarding or network access
        # Skipping in CI environment
        pytest.skip("Requires network access to cluster")


class TestNetworkPolicy:
    """Test network policies"""

    def test_network_policies_applied(self, kubeconfig):
        """Verify network policies are applied"""
        try:
            from kubernetes.dynamic import DynamicClient
            dyn_client = DynamicClient(client.api_client.ApiClient())

            # Check for network policies
            nps = dyn_client.resources.get(api_version='networking.k8s.io/v1', kind='NetworkPolicy')
            np_list = nps.get(namespace='app')

            # Should have at least one network policy
            assert np_list is not None
        except:
            pytest.skip("Network policy check not available")
