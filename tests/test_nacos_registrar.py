#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


REGISTRAR = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None


class Recorder:
    def __init__(self):
        self.condition = threading.Condition()
        self.requests = []
        self.ready = True
        self.login_count = 0
        self.reject_next_heartbeat = False
        self.missing_next_heartbeat = False
        self.auth_required = True
        self.fail_register_count = 0

    def add(self, method, path, params):
        with self.condition:
            self.requests.append((method, path, params))
            self.condition.notify_all()

    def count(self, method, path):
        with self.condition:
            return sum(1 for item in self.requests if item[:2] == (method, path))

    def wait_for(self, method, path, count=1, timeout=8):
        deadline = time.monotonic() + timeout
        with self.condition:
            while self.count(method, path) < count:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.condition.wait(remaining)
        return True


class ReadyHandler(BaseHTTPRequestHandler):
    recorder = None

    def do_GET(self):
        if self.path == '/health/ready' and self.recorder.ready:
            self.send_response(200)
        else:
            self.send_response(503)
        self.end_headers()

    def log_message(self, *_args):
        pass


class NacosHandler(BaseHTTPRequestHandler):
    recorder = None

    def _params(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        length = int(self.headers.get('Content-Length', '0'))
        body = urllib.parse.parse_qs(self.rfile.read(length).decode()) if length else {}
        return {**query, **body}

    def _send(self, status=200, body=b'true', content_type='text/plain'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.end_headers()
        self.wfile.write(body)

    def _record_request(self, method):
        path = urllib.parse.urlsplit(self.path).path
        params = self._params()
        self.recorder.add(method, path, params)
        return path, params

    def do_POST(self):
        path, params = self._record_request('POST')
        if path == '/nacos/v1/auth/users/login':
            self.recorder.login_count += 1
            token = f'test-token-{self.recorder.login_count}'
            self._send(200, json.dumps({'accessToken': token}).encode(), 'application/json')
            return
        if (
            self.recorder.auth_required
            and not params.get('accessToken', [''])[0].startswith('test-token-')
        ):
            self._send(403, b'forbidden')
            return
        if path == '/nacos/v1/ns/instance' and self.recorder.fail_register_count:
            self.recorder.fail_register_count -= 1
            self._send(500, b'unavailable')
            return
        self._send()

    def do_PUT(self):
        path, params = self._record_request('PUT')
        if self.recorder.reject_next_heartbeat:
            self.recorder.reject_next_heartbeat = False
            self._send(401, b'expired')
            return
        if (
            self.recorder.auth_required
            and not params.get('accessToken', [''])[0].startswith('test-token-')
        ):
            self._send(403, b'forbidden')
            return
        if self.recorder.missing_next_heartbeat:
            self.recorder.missing_next_heartbeat = False
            self._send(
                200,
                json.dumps({'code': '20404'}).encode(),
                'application/json',
            )
            return
        self._send()

    def do_DELETE(self):
        path, params = self._record_request('DELETE')
        if (
            self.recorder.auth_required
            and not params.get('accessToken', [''])[0].startswith('test-token-')
        ):
            self._send(403, b'forbidden')
            return
        self._send()

    def log_message(self, *_args):
        pass


def start_server(handler, recorder):
    handler.recorder = recorder
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


class RegistrarLifecycleTest(unittest.TestCase):
    def setUp(self):
        if REGISTRAR is None or not REGISTRAR.is_file():
            self.fail('generated registrar path is required')
        self.recorder = Recorder()
        use_auth = self._testMethodName != 'test_unauthenticated_lifecycle'
        self.recorder.auth_required = use_auth
        self.recorder.fail_register_count = 1 if use_auth else 0
        self.ready_server = start_server(ReadyHandler, self.recorder)
        self.nacos_server = start_server(NacosHandler, self.recorder)
        env = os.environ.copy()
        env.update(
            NACOS_SERVER_URL=f'http://127.0.0.1:{self.nacos_server.server_port}/nacos/',
            NACOS_SERVICE_NAME='outlook-email',
            NACOS_ADVERTISE_IP='198.51.100.24',
            NACOS_ADVERTISE_PORT='5100',
            NACOS_NAMESPACE_ID='public',
            NACOS_GROUP_NAME='DEFAULT_GROUP',
            NACOS_CLUSTER_NAME='DEFAULT',
            REPLICA_READY_URL=f'http://127.0.0.1:{self.ready_server.server_port}/health/ready',
            NACOS_HEARTBEAT_INTERVAL='0.2',
            NACOS_READINESS_INTERVAL='0.1',
            NACOS_RETRY_INITIAL='0.1',
            NACOS_RETRY_MAX='0.5',
            NACOS_HTTP_TIMEOUT='1',
        )
        if use_auth:
            env.update(
                NACOS_USERNAME='nacos-user',
                NACOS_PASSWORD='do-not-log-this',
            )
        else:
            env.pop('NACOS_USERNAME', None)
            env.pop('NACOS_PASSWORD', None)
        self.process = subprocess.Popen(
            [sys.executable, str(REGISTRAR)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.process_output = ''

    def stop_process(self):
        if self.process.poll() is None:
            self.process.terminate()
        output, _ = self.process.communicate(timeout=5)
        self.process_output += output or ''

    def tearDown(self):
        if self.process.stdout is not None and not self.process.stdout.closed:
            self.stop_process()
        self.ready_server.shutdown()
        self.nacos_server.shutdown()
        self.ready_server.server_close()
        self.nacos_server.server_close()

    def assert_request(self, method, path, count=1):
        self.assertTrue(
            self.recorder.wait_for(method, path, count=count),
            f'timed out waiting for {method} {path}; got {self.recorder.requests}',
        )

    def test_lifecycle_refreshes_auth_and_tracks_readiness(self):
        instance_path = '/nacos/v1/ns/instance'
        beat_path = '/nacos/v1/ns/instance/beat'
        self.assert_request('POST', '/nacos/v1/auth/users/login')
        self.assert_request('POST', instance_path, count=2)

        heartbeat_count = self.recorder.count('PUT', beat_path)
        self.recorder.reject_next_heartbeat = True
        self.assert_request('POST', '/nacos/v1/auth/users/login', count=2)
        self.assert_request('PUT', beat_path, count=heartbeat_count + 2)

        register_count = self.recorder.count('POST', instance_path)
        heartbeat_count = self.recorder.count('PUT', beat_path)
        self.recorder.missing_next_heartbeat = True
        self.assert_request('PUT', beat_path, count=heartbeat_count + 1)
        self.assert_request('POST', instance_path, count=register_count + 1)

        self.recorder.ready = False
        self.assert_request('DELETE', instance_path)
        register_count = self.recorder.count('POST', instance_path)
        self.recorder.ready = True
        self.assert_request('POST', instance_path, count=register_count + 1)

        self.stop_process()
        self.assert_request('DELETE', instance_path, count=2)
        self.assertNotIn('do-not-log-this', self.process_output)
        self.assertNotIn('test-token-', self.process_output)

        register = next(
            params
            for method, path, params in self.recorder.requests
            if method == 'POST' and path == instance_path
        )
        self.assertEqual(register['serviceName'], ['outlook-email'])
        self.assertEqual(register['ip'], ['198.51.100.24'])
        self.assertEqual(register['port'], ['5100'])
        self.assertEqual(register['ephemeral'], ['true'])
        self.assertEqual(register['namespaceId'], ['public'])
        self.assertEqual(register['groupName'], ['DEFAULT_GROUP'])
        self.assertEqual(register['clusterName'], ['DEFAULT'])

        deregister = next(
            params
            for method, path, params in self.recorder.requests
            if method == 'DELETE' and path == instance_path
        )
        for key in (
            'serviceName',
            'ip',
            'port',
            'ephemeral',
            'namespaceId',
            'groupName',
            'clusterName',
        ):
            self.assertEqual(deregister[key], register[key])

        heartbeat = next(
            params
            for method, path, params in self.recorder.requests
            if method == 'PUT' and path == beat_path
        )
        beat = json.loads(heartbeat['beat'][0])
        self.assertEqual(heartbeat['namespaceId'], register['namespaceId'])
        self.assertEqual(heartbeat['groupName'], register['groupName'])
        self.assertEqual(beat['serviceName'], register['serviceName'][0])
        self.assertEqual(beat['ip'], register['ip'][0])
        self.assertEqual(str(beat['port']), register['port'][0])
        self.assertEqual(beat['cluster'], register['clusterName'][0])

    def test_unauthenticated_lifecycle(self):
        instance_path = '/nacos/v1/ns/instance'
        beat_path = '/nacos/v1/ns/instance/beat'
        self.assert_request('POST', instance_path)
        self.assert_request('PUT', beat_path)
        self.assertEqual(
            self.recorder.count('POST', '/nacos/v1/auth/users/login'), 0
        )
        self.stop_process()
        self.assert_request('DELETE', instance_path)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
