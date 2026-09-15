"""A throwaway ingest mock for SDK parity gates that lack an in-process
server (the JVM and .NET gates host their own). Answers each path with the
next status in its programmed sequence, echoes Retry-After on 429, and
captures every claim body for the validator.

Usage: mock_server.py <port-file> <capture-dir> envelope=200,400,429,500 claim=200,409,404,500
Serves until killed; writes the chosen port into <port-file> when ready.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

port_file = Path(sys.argv[1])
capture_dir = Path(sys.argv[2])
sequences: dict[str, list[int]] = {}

for spec in sys.argv[3:]:
    name, _, statuses = spec.partition('=')
    sequences[name] = [int(status) for status in statuses.split(',')]

CLAIM_ANSWER = json.dumps({
    'payload': {'promo': 'launch'}, 'path': 'spotify://',
    'clickedAt': '2026-09-15T09:00:00+00:00', 'channel': 'email',
    'campaign': None, 'match': 'clipboard',
}).encode()

lock = threading.Lock()
claim_count = 0


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 - the stdlib's spelling
        global claim_count
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))

        with lock:
            if self.path.endswith('/link/claim'):
                name = 'claim'
                capture_dir.mkdir(parents=True, exist_ok=True)

                if claim_count == 0:
                    (capture_dir / 'claim-request.json').write_bytes(body)

                claim_count += 1
            else:
                name = 'envelope'

            queue = sequences.get(name, [200])
            status = queue.pop(0) if len(queue) > 1 else queue[0]

        answer = CLAIM_ANSWER if name == 'claim' and status == 200 else b'{}'
        self.send_response(status)

        if status == 429:
            self.send_header('Retry-After', '30')

        self.send_header('Content-Length', str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)

    def log_message(self, *args):
        pass


server = HTTPServer(('127.0.0.1', 0), Handler)
port_file.write_text(str(server.server_address[1]))
server.serve_forever()
