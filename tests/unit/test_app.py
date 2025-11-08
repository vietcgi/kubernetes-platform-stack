"""
Unit tests for the application
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../src'))

from app import app
import pytest
import json


@pytest.fixture
def client():
    """Create a test client"""
    app.config['TESTING'] = True
    with app.test_client() as client:
        yield client


class TestHealthEndpoints:
    """Test health check endpoints"""

    def test_health_endpoint(self, client):
        """Test /health endpoint"""
        response = client.get('/health')
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data['status'] == 'healthy'
        assert 'timestamp' in data

    def test_ready_endpoint(self, client):
        """Test /ready endpoint"""
        response = client.get('/ready')
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data['ready'] is True
        assert 'timestamp' in data


class TestAPIEndpoints:
    """Test API endpoints"""

    def test_status_endpoint(self, client):
        """Test /api/v1/status endpoint"""
        response = client.get('/api/v1/status')
        assert response.status_code == 200
        data = json.loads(response.data)
        assert 'app' in data
        assert 'version' in data
        assert 'environment' in data
        assert data['app'] == 'kubernetes-platform-stack'

    def test_config_endpoint(self, client):
        """Test /api/v1/config endpoint"""
        response = client.get('/api/v1/config')
        assert response.status_code == 200
        data = json.loads(response.data)
        assert 'app' in data
        assert 'port' in data

    def test_echo_endpoint_post(self, client):
        """Test /api/v1/echo POST endpoint"""
        test_data = {'message': 'test', 'value': 123}
        response = client.post(
            '/api/v1/echo',
            data=json.dumps(test_data),
            content_type='application/json'
        )
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data['data'] == test_data
        assert data['message'] == 'echo received'


class TestMetricsEndpoint:
    """Test metrics endpoint"""

    def test_metrics_endpoint(self, client):
        """Test /metrics endpoint"""
        response = client.get('/metrics')
        assert response.status_code == 200
        assert 'app_requests_total' in response.data.decode()
        assert 'HELP' in response.data.decode()


class TestErrorHandling:
    """Test error handling"""

    def test_404_not_found(self, client):
        """Test 404 error handling"""
        response = client.get('/nonexistent')
        assert response.status_code == 404
        data = json.loads(response.data)
        assert 'error' in data

    def test_invalid_post_data(self, client):
        """Test invalid POST data handling"""
        response = client.post('/api/v1/echo', data='invalid')
        assert response.status_code in [400, 415]
