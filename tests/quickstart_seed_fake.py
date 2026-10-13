#!/usr/bin/env python3
"""Fake instance metadata service and Cosmos DB REST endpoint for tests/Test-QuickstartSeed.ps1.

Runs infra/quickstart/runner/seed-cosmos.py (the script step 5 sends through Run Command) against
an in-process HTTP server and prints one JSON object with each scenario's output and the requests
the server saw. The server behaves as Cosmos DB's documented REST API does for the calls the seed
makes: Get Document (200, 404), Create Document (201, 409), and it records the headers so the test
can check the Microsoft Entra authorization string, the partition key and that no upsert is asked.

Usage: python quickstart_seed_fake.py <path to seed-cosmos.py> <work directory> <work directory>
"""

import json
import os
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PARTITION_PATHS = {"projects": "projectId", "backends": "backendId"}
TOKEN = "fake-token-123"


class State:
    def __init__(self):
        self.store = {}
        self.requests = []
        self.forbid = 0
        self.lock = threading.Lock()


STATE = State()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body=None):
        raw = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("x-ms-session-token", "0:1#1")
        self.end_headers()
        self.wfile.write(raw)

    def record(self, body=None):
        with STATE.lock:
            STATE.requests.append({
                "method": self.command,
                "path": urllib.parse.urlsplit(self.path).path,
                "query": urllib.parse.urlsplit(self.path).query,
                "authorization": urllib.parse.unquote(self.headers.get("Authorization", "")),
                "metadata": self.headers.get("Metadata"),
                "partitionKey": self.headers.get("x-ms-documentdb-partitionkey"),
                "version": self.headers.get("x-ms-version"),
                "date": self.headers.get("x-ms-date"),
                "upsert": self.headers.get("x-ms-documentdb-is-upsert"),
                "body": body,
            })

    def cosmos_allowed(self):
        if urllib.parse.unquote(self.headers.get("Authorization", "")) != f"type=aad&ver=1.0&sig={TOKEN}":
            self.send(401, {"code": "Unauthorized"})
            return False
        with STATE.lock:
            if STATE.forbid > 0:
                STATE.forbid -= 1
                self.send(403, {"code": "Forbidden"})
                return False
        return True

    def do_GET(self):
        self.record()
        parts = urllib.parse.urlsplit(self.path)
        if parts.path == "/metadata/identity/oauth2/token":
            if self.headers.get("Metadata") != "true":
                return self.send(400, {"error": "missing Metadata header"})
            return self.send(200, {"access_token": TOKEN, "token_type": "Bearer"})
        segments = [urllib.parse.unquote(s) for s in parts.path.split("/")]
        # ['', 'dbs', db, 'colls', container, 'docs', id]
        if len(segments) != 7 or segments[1] != "dbs" or segments[3] != "colls" or segments[5] != "docs":
            return self.send(400, {"code": "BadRequest"})
        if not self.cosmos_allowed():
            return None
        key = (segments[4], segments[6])
        doc = STATE.store.get(key)
        if doc is None:
            return self.send(404, {"code": "NotFound"})
        if json.loads(self.headers.get("x-ms-documentdb-partitionkey", "null")) != [doc[PARTITION_PATHS[segments[4]]]]:
            return self.send(400, {"code": "BadRequest", "message": "partition key"})
        return self.send(200, {**doc, "_rid": "x", "_self": "y", "_etag": "\"z\"", "_attachments": "a/", "_ts": 1})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"null")
        self.record(body)
        segments = [urllib.parse.unquote(s) for s in urllib.parse.urlsplit(self.path).path.split("/")]
        if len(segments) != 6 or segments[1] != "dbs" or segments[3] != "colls" or segments[5] != "docs":
            return self.send(400, {"code": "BadRequest"})
        if not self.cosmos_allowed():
            return None
        if self.headers.get("x-ms-documentdb-is-upsert"):
            return self.send(403, {"code": "Forbidden", "message": "the role has no upsert"})
        container = segments[4]
        if json.loads(self.headers.get("x-ms-documentdb-partitionkey", "null")) != [body[PARTITION_PATHS[container]]]:
            return self.send(400, {"code": "BadRequest", "message": "partition key"})
        key = (container, body["id"])
        with STATE.lock:
            if key in STATE.store:
                return self.send(409, {"code": "Conflict"})
            STATE.store[key] = body
        return self.send(201, {**body, "_rid": "x"})


def run_seed(seed, port, entries, folder):
    path = os.path.join(folder, "documents.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(entries, handle)
    before = len(STATE.requests)
    result = subprocess.run(
        [sys.executable, seed, f"http://127.0.0.1:{port}/", "ccof", path, f"http://127.0.0.1:{port}", "0"],
        capture_output=True, text=True, timeout=120)
    os.remove(path)
    return {"exit": result.returncode, "stdout": result.stdout.splitlines(), "stderr": result.stderr[-2000:], "requests": STATE.requests[before:]}


def main():
    seed, folder = sys.argv[1], sys.argv[2]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    project = {"id": "P1", "projectId": "P1", "status": "active", "classifications": {"STD": {"groupId": "g"}}}
    backend = {"id": "b-1", "backendId": "b-1", "status": "active", "apiFormat": "anthropic-messages", "auth": {"mode": "managed-identity", "resource": "https://cognitiveservices.azure.com"}}
    entries = [
        {"container": "projects", "partitionKey": "P1", "document": project},
        {"container": "backends", "partitionKey": "b-1", "document": backend},
    ]
    out = {"port": port}
    out["first"] = run_seed(seed, port, entries, folder)
    out["rerun"] = run_seed(seed, port, entries, folder)
    changed = json.loads(json.dumps(project))
    changed["classifications"]["STD"]["groupId"] = "other"
    out["differs"] = run_seed(seed, port, [{"container": "projects", "partitionKey": "P1", "document": changed}], folder)
    out["storedAfterDiffers"] = STATE.store[("projects", "P1")]
    STATE.forbid = 2
    out["forbiddenThenAllowed"] = run_seed(seed, port, [{"container": "projects", "partitionKey": "P2", "document": {**project, "id": "P2", "projectId": "P2"}}], folder)
    STATE.forbid = 1000
    out["forbidden"] = run_seed(seed, port, [{"container": "projects", "partitionKey": "P3", "document": {**project, "id": "P3", "projectId": "P3"}}], folder)
    STATE.forbid = 0
    server.shutdown()
    print(json.dumps(out))


if __name__ == "__main__":
    main()
