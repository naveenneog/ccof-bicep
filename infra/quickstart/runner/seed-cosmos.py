#!/usr/bin/env python3
"""Quick-start step 5 (ADR-0024): create the projects and backends documents in Cosmos DB from
inside the VNet with this VM's managed identity, then read every one back and compare it.

Usage:
  python3 seed-cosmos.py <account endpoint> <database> <documents.json> [<identity endpoint> [<retry seconds>]]

documents.json is a JSON array of {"container", "partitionKey", "document"}; each document's id is
document["id"]. The script prints one line per document, "CCOF_SEED <json>", then a last line,
"CCOF_SEED_DONE <json>", and exits 0 only when every document is created or already present.

Only the Python standard library is used, so a stock Ubuntu image needs nothing installed and no
internet egress: the token comes from the instance metadata service and Cosmos DB is reached
through its private endpoint.

The runner's Cosmos role allows read and create only (ADR-0024, D-7: no upsert, no replace), so an
existing document is never overwritten: one equal to the parameters is "present"; one that differs
is reported as "differs" with the names of its differing top-level fields, never their values.

References (retrieved 2026-10-13):
- Cosmos DB REST authorization with Microsoft Entra ID: "type=aad&ver=1.0&sig=<token>", URL-encoded
  (https://learn.microsoft.com/rest/api/cosmos-db/access-control-on-cosmosdb-resources).
- Create Document: POST .../dbs/{db}/colls/{coll}/docs, 201 Created, 409 Conflict when the id
  exists; Get Document: GET .../docs/{id}; both with x-ms-documentdb-partitionkey
  (https://learn.microsoft.com/rest/api/cosmos-db/create-a-document,
  https://learn.microsoft.com/rest/api/cosmos-db/get-a-document).
- Managed identity token from IMDS: GET /metadata/identity/oauth2/token?api-version=2018-02-01
  &resource=<resource> with "Metadata: true"
  (https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token).
"""

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from email.utils import formatdate

API_VERSION = "2018-12-31"
SYSTEM_PROPERTIES = ("_rid", "_self", "_etag", "_attachments", "_ts")
# 401 and 403 are retried too: a new data-plane role assignment can take minutes to apply.
RETRY_STATUSES = (0, 401, 403, 408, 429, 449, 500, 502, 503, 504)
ATTEMPTS = 20


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def without_system(document):
    return {k: v for k, v in document.items() if k not in SYSTEM_PROPERTIES}


class Cosmos:
    def __init__(self, endpoint, database, identity, retry_seconds):
        parts = urllib.parse.urlsplit(endpoint)
        port = f":{parts.port}" if parts.port else ""
        self.base = f"{parts.scheme}://{parts.hostname}{port}"
        self.resource = f"https://{parts.hostname}"
        self.database = database
        self.identity = identity.rstrip("/")
        self.retry_seconds = retry_seconds
        self.token = None

    def get_token(self):
        if self.token is None:
            query = urllib.parse.urlencode({"api-version": "2018-02-01", "resource": self.resource})
            request = urllib.request.Request(f"{self.identity}/metadata/identity/oauth2/token?{query}", headers={"Metadata": "true"})
            with urllib.request.urlopen(request, timeout=30) as response:
                self.token = json.loads(response.read())["access_token"]
        return self.token

    def call(self, method, path, partition_key, body=None, session=None):
        """Returns (status, parsed body or None, session token), retrying transient answers."""
        status, session_token = 0, None
        for attempt in range(ATTEMPTS):
            try:
                headers = {
                    "Authorization": urllib.parse.quote(f"type=aad&ver=1.0&sig={self.get_token()}", safe=""),
                    "x-ms-date": formatdate(usegmt=True),
                    "x-ms-version": API_VERSION,
                    "x-ms-documentdb-partitionkey": json.dumps([partition_key]),
                    "Accept": "application/json",
                }
                if session:
                    headers["x-ms-session-token"] = session
                data = None
                if body is not None:
                    data = json.dumps(body).encode("utf-8")
                    headers["Content-Type"] = "application/json"
                request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
                with urllib.request.urlopen(request, timeout=60) as response:
                    raw = response.read()
                    return response.status, (json.loads(raw) if raw else None), response.headers.get("x-ms-session-token")
            except urllib.error.HTTPError as error:
                status = error.code
                session_token = error.headers.get("x-ms-session-token") if error.headers else None
                error.read()
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                status = 0
            if status not in RETRY_STATUSES:
                return status, None, session_token
            if status in (401, 403):
                self.token = None
            if attempt < ATTEMPTS - 1:
                time.sleep(self.retry_seconds)
        return status, None, session_token

    def docs_path(self, container):
        return f"/dbs/{urllib.parse.quote(self.database, safe='')}/colls/{urllib.parse.quote(container, safe='')}/docs"

    def read(self, container, doc_id, partition_key, session=None):
        return self.call("GET", f"{self.docs_path(container)}/{urllib.parse.quote(doc_id, safe='')}", partition_key, session=session)

    def create(self, container, document, partition_key):
        return self.call("POST", self.docs_path(container), partition_key, body=document)


def differing_fields(stored, wanted):
    keys = set(stored) | set(wanted)
    return sorted(k for k in keys if canonical(stored.get(k)) != canonical(wanted.get(k)))


def seed_one(cosmos, entry):
    container, partition_key, wanted = entry["container"], entry["partitionKey"], entry["document"]
    line = {"container": container, "id": wanted["id"]}
    status, stored, _ = cosmos.read(container, wanted["id"], partition_key)
    outcome = "present"
    if status == 404:
        status, _, session = cosmos.create(container, wanted, partition_key)
        if status == 201:
            outcome = "created"
        elif status != 409:
            return {**line, "outcome": "failed", "step": "create", "status": status}
        # Created now, or by a concurrent run (409): read it back in either case.
        for _ in range(5):
            status, stored, _ = cosmos.read(container, wanted["id"], partition_key, session=session)
            if status != 404:
                break
            time.sleep(cosmos.retry_seconds)
        if status != 200:
            return {**line, "outcome": "failed", "step": "read-back", "status": status}
    elif status != 200:
        return {**line, "outcome": "failed", "step": "read", "status": status}
    fields = differing_fields(without_system(stored or {}), wanted)
    if fields:
        return {**line, "outcome": "differs", "fields": fields, "status": status}
    return {**line, "outcome": outcome, "status": status}


def main(argv):
    if len(argv) < 4 or len(argv) > 6:
        print('CCOF_SEED_DONE {"ok":false,"reason":"usage"}')
        return 2
    endpoint, database, path = argv[1], argv[2], argv[3]
    identity = argv[4] if len(argv) > 4 else "http://169.254.169.254"
    retry_seconds = float(argv[5]) if len(argv) > 5 else 15.0
    with open(path, encoding="utf-8") as handle:
        entries = json.load(handle)
    cosmos = Cosmos(endpoint, database, identity, retry_seconds)
    counts = {"created": 0, "present": 0, "differs": 0, "failed": 0}
    for entry in entries:
        try:
            result = seed_one(cosmos, entry)
        except Exception as error:  # one line per document, whatever happens to it
            result = {"container": entry.get("container"), "id": (entry.get("document") or {}).get("id"), "outcome": "failed", "step": "exception", "error": type(error).__name__}
        counts[result["outcome"]] += 1
        print("CCOF_SEED " + json.dumps(result, separators=(",", ":")), flush=True)
    ok = counts["differs"] == 0 and counts["failed"] == 0
    print("CCOF_SEED_DONE " + json.dumps({"ok": ok, **counts}, separators=(",", ":")), flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
