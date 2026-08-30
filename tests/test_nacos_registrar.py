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

    def add(self, method, path, params, authorization=''):
        with self.condition:
            self.requests.append((method, path, params, authorization))
            self.condition.notify_all()

    def count_matching(self, method, path, expected=None):
        expected = expected or {}
        with self.condition:
            return sum(
                1
                for request_method, request_path, params, _authorization
                in self.requests
                if request_method == method
                and request_path == path
                and all(
                    params.get(key) == [value]
                    for key, value in expected.items()
                )
            )

    def wait_for_matching(
        self, method, path, expected=None, count=1, timeout=8
    ):
        deadline = time.monotonic() + timeout
        with self.condition:
            while self.count_matching(method, path, expected) < count:
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
        authorization = self.headers.get('Authorization', '')
        self.recorder.add(method, path, params, authorization)
        return path, params, authorization

    def _send_result(self, code=0, message='success', data='ok'):
        self._send(
            200,
            json.dumps(
                {'code': code, 'message': message, 'data': data}
            ).encode(),
            'application/json',
        )

    def _authorized(self, params, authorization):
        if 'accessToken' in params:
            return False
        return (
            not self.recorder.auth_required
            or authorization.startswith('Bearer test-token-')
        )

    def do_POST(self):
        path, params, authorization = self._record_request('POST')
        if path == '/nacos/v3/auth/user/login':
            self.recorder.login_count += 1
            token = f'test-token-{self.recorder.login_count}'
            self._send(200, json.dumps({'accessToken': token}).encode(), 'application/json')
            return
        if not self._authorized(params, authorization):
            self._send(403, b'forbidden')
            return
        if path != '/nacos/v3/client/ns/instance':
            self._send(404, b'not found')
            return
        heartbeat = params.get('heartBeat') == ['true']
        if heartbeat and self.recorder.reject_next_heartbeat:
            self.recorder.reject_next_heartbeat = False
            self._send(401, b'expired')
            return
        if heartbeat and self.recorder.missing_next_heartbeat:
            self.recorder.missing_next_heartbeat = False
            self._send_result(21003, 'instance not found', None)
            return
        if not heartbeat and self.recorder.fail_register_count:
            self.recorder.fail_register_count -= 1
            self._send(500, b'unavailable')
            return
        self._send_result()

    def do_PUT(self):
        self._record_request('PUT')
        self._send(405, b'method not allowed')

    def do_DELETE(self):
        path, params, authorization = self._record_request('DELETE')
        if not self._authorized(params, authorization):
            self._send(403, b'forbidden')
            return
        if path != '/nacos/v3/client/ns/instance':
            self._send(404, b'not found')
            return
        self._send_result()

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

    def assert_request(self, method, path, expected=None, count=1):
        self.assertTrue(
            self.recorder.wait_for_matching(
                method, path, expected=expected, count=count
            ),
            f'timed out waiting for {method} {path}; got {self.recorder.requests}',
        )

    def test_lifecycle_refreshes_auth_and_tracks_readiness(self):
        login_path = '/nacos/v3/auth/user/login'
        instance_path = '/nacos/v3/client/ns/instance'
        register_params = {'heartBeat': 'false'}
        heartbeat_params = {'heartBeat': 'true'}
        self.assert_request('POST', login_path)
        self.assert_request('POST', instance_path, register_params, count=2)

        heartbeat_count = self.recorder.count_matching(
            'POST', instance_path, heartbeat_params
        )
        self.recorder.reject_next_heartbeat = True
        self.assert_request('POST', login_path, count=2)
        self.assert_request(
            'POST',
            instance_path,
            heartbeat_params,
            count=heartbeat_count + 2,
        )

        register_count = self.recorder.count_matching(
            'POST', instance_path, register_params
        )
        heartbeat_count = self.recorder.count_matching(
            'POST', instance_path, heartbeat_params
        )
        self.recorder.missing_next_heartbeat = True
        self.assert_request(
            'POST',
            instance_path,
            heartbeat_params,
            count=heartbeat_count + 1,
        )
        self.assert_request(
            'POST', instance_path, register_params, count=register_count + 1
        )

        self.recorder.ready = False
        self.assert_request('DELETE', instance_path)
        register_count = self.recorder.count_matching(
            'POST', instance_path, register_params
        )
        self.recorder.ready = True
        self.assert_request(
            'POST', instance_path, register_params, count=register_count + 1
        )

        self.stop_process()
        self.assert_request('DELETE', instance_path, count=2)
        self.assertNotIn('do-not-log-this', self.process_output)
        self.assertNotIn('test-token-', self.process_output)

        register = next(
            params
            for method, path, params, _authorization in self.recorder.requests
            if method == 'POST'
            and path == instance_path
            and params.get('heartBeat') == ['false']
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
            for method, path, params, _authorization in self.recorder.requests
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
            for method, path, params, _authorization in self.recorder.requests
            if method == 'POST'
            and path == instance_path
            and params.get('heartBeat') == ['true']
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
            self.assertEqual(heartbeat[key], register[key])

        instance_requests = [
            request
            for request in self.recorder.requests
            if request[1] == instance_path
        ]
        self.assertTrue(instance_requests)
        self.assertTrue(
            all(
                authorization.startswith('Bearer test-token-')
                for _method, _path, _params, authorization
                in instance_requests
            )
        )
        self.assertTrue(
            all(
                'accessToken' not in params
                for _method, _path, params, _authorization
                in self.recorder.requests
            )
        )
        self.assertFalse(
            any(method == 'PUT' for method, *_rest in self.recorder.requests)
        )

    def test_unauthenticated_lifecycle(self):
        login_path = '/nacos/v3/auth/user/login'
        instance_path = '/nacos/v3/client/ns/instance'
        self.assert_request('POST', instance_path, {'heartBeat': 'false'})
        self.assert_request('POST', instance_path, {'heartBeat': 'true'})
        self.assertEqual(
            self.recorder.count_matching('POST', login_path), 0
        )
        self.stop_process()
        self.assert_request('DELETE', instance_path)
        self.assertTrue(
            all(
                not authorization
                for _method, _path, _params, authorization
                in self.recorder.requests
            )
        )
        self.assertTrue(
            all(
                'accessToken' not in params
                for _method, _path, params, _authorization
                in self.recorder.requests
            )
        )


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
