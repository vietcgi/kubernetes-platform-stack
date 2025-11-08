#!/usr/bin/env python3
"""
Kubernetes Platform Stack - Example Application
"""

from flask import Flask, jsonify, request
import logging
import os
from datetime import datetime
import json

app = Flask(__name__)

# Setup logging
logging.basicConfig(level=os.getenv('LOG_LEVEL', 'INFO'))
logger = logging.getLogger(__name__)

# Application info
APP_NAME = "kubernetes-platform-stack"
APP_VERSION = "1.0.0"
ENVIRONMENT = os.getenv('ENVIRONMENT', 'unknown')


@app.route('/health', methods=['GET'])
def health():
    """Liveness probe endpoint"""
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat()
    }), 200


@app.route('/ready', methods=['GET'])
def ready():
    """Readiness probe endpoint"""
    return jsonify({
        'ready': True,
        'timestamp': datetime.utcnow().isoformat()
    }), 200


@app.route('/api/v1/status', methods=['GET'])
def status():
    """API status endpoint"""
    return jsonify({
        'app': APP_NAME,
        'version': APP_VERSION,
        'environment': ENVIRONMENT,
        'timestamp': datetime.utcnow().isoformat()
    }), 200


@app.route('/api/v1/echo', methods=['POST'])
def echo():
    """Echo endpoint for testing request/response"""
    try:
        data = request.get_json()
        logger.info(f"Echo request received: {data}")
        return jsonify({
            'message': 'echo received',
            'data': data,
            'timestamp': datetime.utcnow().isoformat()
        }), 200
    except Exception as e:
        logger.error(f"Error in echo endpoint: {str(e)}")
        return jsonify({'error': str(e)}), 400


@app.route('/metrics', methods=['GET'])
def metrics():
    """Prometheus metrics endpoint"""
    # Simple metrics in Prometheus text format
    metrics_data = """# HELP app_requests_total Total application requests
# TYPE app_requests_total counter
app_requests_total{method="GET",path="/health"} 100
app_requests_total{method="GET",path="/ready"} 50
app_requests_total{method="GET",path="/api/v1/status"} 30

# HELP app_request_duration_seconds Request latency
# TYPE app_request_duration_seconds histogram
app_request_duration_seconds_bucket{le="0.1"} 95
app_request_duration_seconds_bucket{le="0.5"} 98
app_request_duration_seconds_bucket{le="1.0"} 100

# HELP app_info Application info
# TYPE app_info gauge
app_info{app="kubernetes-platform-stack",version="1.0.0",environment="unknown"} 1
"""
    return metrics_data, 200, {'Content-Type': 'text/plain'}


@app.route('/api/v1/config', methods=['GET'])
def config():
    """Configuration info endpoint"""
    return jsonify({
        'app': APP_NAME,
        'version': APP_VERSION,
        'environment': ENVIRONMENT,
        'port': os.getenv('PORT', 8080),
        'log_level': os.getenv('LOG_LEVEL', 'INFO'),
        'timestamp': datetime.utcnow().isoformat()
    }), 200


@app.errorhandler(404)
def not_found(error):
    """Handle 404 errors"""
    return jsonify({'error': 'not found'}), 404


@app.errorhandler(500)
def internal_error(error):
    """Handle 500 errors"""
    logger.error(f"Internal error: {str(error)}")
    return jsonify({'error': 'internal server error'}), 500


@app.before_request
def log_request():
    """Log incoming requests"""
    logger.debug(f"{request.method} {request.path}")


@app.after_request
def log_response(response):
    """Log outgoing responses"""
    logger.debug(f"Response: {response.status_code}")
    return response


if __name__ == '__main__':
    port = int(os.getenv('PORT', 8080))
    logger.info(f"Starting {APP_NAME} v{APP_VERSION} on port {port}")
    app.run(host='0.0.0.0', port=port, debug=False)
