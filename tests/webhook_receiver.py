#!/usr/bin/env python3
"""Webhook receiver for tests: verifies X-Museum-Signature-256 and logs.

    webhook_receiver.py <port> <secret> <log.jsonl> [fail_first]

Answers 500 to the first `fail_first` non-ping requests (to exercise
museum's retry), then 200; pings are always accepted.  Every request is one JSON line in the log:
{"n", "status", "event", "delivery", "signature_ok", "body"}.
"""
import hashlib, hmac, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, SECRET, LOG = int(sys.argv[1]), sys.argv[2].encode(), sys.argv[3]
FAIL_FIRST = int(sys.argv[4]) if len(sys.argv) > 4 else 0
COUNT = [0]

class Hook(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        want = "sha256=" + hmac.new(SECRET, raw, hashlib.sha256).hexdigest()
        got = self.headers.get("X-Museum-Signature-256", "")
        event = self.headers.get("X-Museum-Event")
        if event != "ping":
            COUNT[0] += 1
        status = 500 if event != "ping" and COUNT[0] <= FAIL_FIRST else 200
        with open(LOG, "a") as f:
            f.write(json.dumps({"n": COUNT[0], "status": status,
                                "event": event,
                                "delivery": self.headers.get("X-Museum-Delivery"),
                                "content_type": self.headers.get("Content-Type"),
                                "signature_ok": hmac.compare_digest(want, got),
                                "body": json.loads(raw or b"null")}) + "\n")
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", PORT), Hook).serve_forever()
