#!/usr/bin/env python3
"""Exercise the native Swift host over real MCP HTTP/SSE and OAuth; never call Apple."""
import argparse
import base64
import hashlib
import http.client
import json
import os
import re
import secrets
import socket
import sys
import subprocess
import tempfile
import time
import urllib.parse
from pathlib import Path


def check(value, message):
    if not value:
        raise AssertionError(message)


def run(binary):
    with tempfile.TemporaryDirectory(prefix="asc-http-smoke-") as tmp:
        tmp = Path(tmp)
        key = tmp / "test.p8"
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)], check=True, capture_output=True)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        origin = f"http://127.0.0.1:{port}"
        password, automation = secrets.token_hex(32), secrets.token_hex(32)
        config = {"companies": [{"id": name, "name": name, "key_id": "TEST", "issuer_id": "TEST", "key_content": key.read_text()} for name in ["alpha", "beta"]]}
        env = dict(os.environ, MCP_PUBLIC_URL=origin, MCP_ADMIN_PASSWORD=password, MCP_BEARER_TOKEN=automation, PORT=str(port), MCP_DATA_DIR=str(tmp / "data"), ASC_COMPANIES_JSON=json.dumps(config), ASC_TRANSPORT="http")
        log = open(tmp / "server.log", "wb")
        process = subprocess.Popen([str(Path(binary).resolve()), "--http"], env=env, stdout=log, stderr=log)

        def request(method, path, payload=None, token=None, session=None, form=False, raw=False, extra=None):
            headers = dict(extra or {})
            if token:
                headers["Authorization"] = "Bearer " + token
            if session:
                headers["MCP-Session-Id"] = session
                headers["MCP-Protocol-Version"] = "2025-11-25"
            if path == "/mcp":
                headers["Accept"] = "application/json, text/event-stream"
            if payload is not None:
                if raw:
                    body = payload
                    headers["Content-Type"] = "application/octet-stream"
                elif form:
                    body = urllib.parse.urlencode(payload).encode()
                    headers["Content-Type"] = "application/x-www-form-urlencoded"
                else:
                    body = json.dumps(payload).encode()
                    headers["Content-Type"] = "application/json"
            else:
                body = None
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            status, response_headers = response.status, dict(response.getheaders())
            data = response.read()
            connection.close()
            return status, {k.lower(): v for k, v in response_headers.items()}, data

        counter = 0
        def rpc(method, params=None, token=automation, session=None):
            nonlocal counter
            counter += 1
            status, headers, data = request("POST", "/mcp", {"jsonrpc": "2.0", "id": counter, "method": method, "params": params or {}}, token, session)
            if status != 200:
                return status, headers, None
            messages = [json.loads(line[6:]) for line in data.decode().splitlines() if line.startswith("data: ") and line[6:].strip()]
            if not messages:
                messages = [json.loads(data)]
            result = next((m for m in messages if m.get("id") == counter), None)
            check(result is not None, "MCP response ID mismatch")
            return status, headers, result

        def initialize(token=automation):
            status, headers, message = rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "native-http-smoke", "version": "1"}}, token)
            check(status == 200 and "result" in message, "initialize failed")
            session = headers.get("mcp-session-id")
            check(session, "Session ID missing")
            status, _, _ = request("POST", "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, token, session)
            check(status == 202, "initialized notification not accepted")
            return session

        def call(session, name, arguments=None, token=automation):
            status, _, message = rpc("tools/call", {"name": name, "arguments": arguments or {}}, token, session)
            check(status == 200 and "result" in message, "tools/call failed")
            return message["result"]

        def structured(result):
            return result.get("structuredContent") or json.loads(result["content"][0]["text"])

        try:
            for _ in range(300):
                if process.poll() is not None:
                    raise RuntimeError((tmp / "server.log").read_text()[-6000:])
                try:
                    if request("GET", "/health/ready")[0] == 200:
                        break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("Server did not become ready")
            check(request("POST", "/mcp", {})[0] == 401, "Unauthenticated MCP allowed")
            check(request("GET", "/", extra={"Origin": "https://attacker.example"})[0] == 403, "Untrusted origin allowed")
            session_a, session_b = initialize(), initialize()
            _, _, message = rpc("tools/list", session=session_a)
            tools = message["result"]["tools"]
            names = [tool["name"] for tool in tools]
            check(len(names) == 507 and len(set(names)) == 507, f"Expected all 502 upstream + 5 cloud tools, got {len(names)}")
            for name in ["apps_list", "subscriptions_list", "xcode_cloud_products_list", "screenshots_upload", "build_uploads_upload", "auth_generate_token"]:
                check(name in names, "Missing original tool " + name)
            check(not call(session_a, "company_switch", {"company": "beta"}).get("isError"), "Company switch failed")
            check("beta" in json.dumps(call(session_a, "company_current")), "Company not switched")
            check("alpha" in json.dumps(call(session_b, "company_current")), "Sessions leaked company state")
            check(call(session_a, "builds_get", {}).get("isError"), "Missing input did not fail safely")
            check(call(session_a, "unknown_tool", {}).get("isError"), "Unknown tool did not fail")
            check(call(session_a, "screenshots_upload", {"file_path": str(key)}).get("isError"), "Private key path accepted")
            ticket = structured(call(session_a, "bridge_files_create_upload", {"file_name": "test.txt"}))
            upload_path = urllib.parse.urlparse(ticket["upload_url"]).path
            check(request("GET", upload_path)[0] == 200, "Upload portal missing")
            status, _, data = request("POST", upload_path, b"cloud upload fixture", raw=True)
            check(status == 200, "File upload failed")
            asset = json.loads(data)
            check(asset["file_size"] == 20 and Path(asset["file_path"]).read_bytes() == b"cloud upload fixture", "Uploaded bytes differ")
            check(request("POST", upload_path, b"replay", raw=True)[0] == 404, "Upload ticket reusable")
            check(asset["file_id"] in json.dumps(call(session_a, "bridge_files_list")), "Stored asset missing")
            job_input = {"tool_name": "company_current", "arguments": {}, "operation_id": "smoke-job"}
            job = structured(call(session_a, "bridge_jobs_submit", job_input))
            duplicate = structured(call(session_a, "bridge_jobs_submit", job_input))
            check(job["job_id"] == duplicate["job_id"], "Duplicate job executed twice")
            for _ in range(50):
                receipt = structured(call(session_a, "bridge_jobs_get", {"job_id": job["job_id"]}))
                if receipt["status"] != "running":
                    break
                time.sleep(0.05)
            check(receipt["status"] == "completed" and "original_result" in receipt, "Original job result missing")
            check("beta" in json.dumps(receipt["original_result"]), "Job account snapshot incorrect")
            conflict = dict(job_input, arguments={"extra": True})
            check(call(session_a, "bridge_jobs_submit", conflict).get("isError"), "Operation ID collision accepted")

            # Modern requests use explicit context handles and no HTTP sessions.
            def modern(method, params=None, version="2026-07-28", header_name=None):
                nonlocal counter
                counter += 1
                params = dict(params or {})
                params["_meta"] = {"io.modelcontextprotocol/protocolVersion": version,
                    "io.modelcontextprotocol/clientInfo": {"name": "modern-smoke", "version": "1"},
                    "io.modelcontextprotocol/clientCapabilities": {}}
                extra = {"MCP-Protocol-Version": version, "Mcp-Method": method}
                if method == "tools/call": extra["Mcp-Name"] = header_name or params.get("name", "")
                status, headers, data = request("POST", "/mcp", {"jsonrpc": "2.0", "id": counter, "method": method, "params": params}, token=automation, extra=extra)
                check("mcp-session-id" not in headers, "Modern transport leaked a session ID")
                return status, json.loads(data)
            status, discovery = modern("server/discover")
            check(status == 200 and "2026-07-28" in discovery["result"]["supportedVersions"], "Modern discovery failed")
            status, catalog = modern("tools/list")
            check(status == 200 and len(catalog["result"]["tools"]) == 507, "Modern catalog missing tools")
            status, created = modern("tools/call", {"name": "bridge_context_create", "arguments": {}})
            context = structured(created["result"])["context_id"]
            status, current = modern("tools/call", {"name": "company_current", "arguments": {"context_id": context}})
            check(status == 200 and current["result"]["resultType"] == "complete" and "alpha" in json.dumps(current), "Modern context failed")
            status, denied = modern("tools/call", {"name": "company_current", "arguments": {}})
            check(denied["result"].get("isError"), "Modern call accepted implicit company state")
            status, mismatch = modern("tools/call", {"name": "company_current", "arguments": {"context_id": context}}, header_name="apps_list")
            check(status == 400 and "error" in mismatch, "Header/body method mismatch accepted")
            status, unsupported = modern("server/discover", version="2099-01-01")
            check(status == 400 and unsupported["error"]["code"] == -32022, "Unknown protocol not negotiated correctly")

            # Full OAuth authorization-code + PKCE flow, refresh rotation and revocation.
            status, _, data = request("GET", "/.well-known/oauth-protected-resource")
            check(status == 200 and json.loads(data)["resource"] == origin + "/mcp", "Resource discovery incorrect")
            redirect = "https://client.example/callback"
            status, _, data = request("POST", "/oauth/register", {"redirect_uris": [redirect], "client_name": "Smoke client", "token_endpoint_auth_method": "none"})
            check(status == 201, "DCR failed")
            client = json.loads(data)["client_id"]
            verifier = secrets.token_urlsafe(48)
            challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
            fields = {"client_id": client, "redirect_uri": redirect, "response_type": "code", "code_challenge_method": "S256", "code_challenge": challenge, "resource": origin + "/mcp", "state": "test-state", "scope": "asc:read offline_access"}
            status, _, page = request("GET", "/oauth/authorize?" + urllib.parse.urlencode(fields))
            check(status == 200, "Owner authorization page failed")
            flow = re.search(r'name="flow" value="([^"]+)"', page.decode()).group(1)
            check(request("POST", "/oauth/authorize", {"flow": flow, "password": "wrong"}, form=True)[0] == 403, "Wrong owner password accepted")
            status, headers, _ = request("POST", "/oauth/authorize", {"flow": flow, "password": password}, form=True)
            check(status == 303, "Owner consent failed")
            query = urllib.parse.parse_qs(urllib.parse.urlparse(headers["location"]).query)
            check(query["state"] == ["test-state"] and query["iss"] == [origin], "OAuth state/issuer not preserved")
            exchange = {"grant_type": "authorization_code", "client_id": client, "redirect_uri": redirect, "resource": origin + "/mcp", "code": query["code"][0], "code_verifier": verifier}
            status, _, data = request("POST", "/oauth/token", exchange, form=True)
            check(status == 200, "PKCE token exchange failed")
            credentials = json.loads(data)
            check(request("POST", "/oauth/token", exchange, form=True)[0] == 400, "Authorization code reusable")
            read_token = credentials["access_token"]
            read_session = initialize(read_token)
            check(rpc("tools/list", token=read_token, session=session_a)[0] == 404, "OAuth grant accessed automation session")
            check(call(read_session, "apps_update_metadata", {}, read_token).get("isError"), "Read-only grant could write")
            check(call(read_session, "auth_generate_token", {}, read_token).get("isError"), "Read-only grant exposed Apple JWT")
            check(asset["file_id"] not in json.dumps(call(read_session, "bridge_files_list", token=read_token)), "OAuth grants leaked files")
            refresh = {"grant_type": "refresh_token", "client_id": client, "resource": origin + "/mcp", "refresh_token": credentials["refresh_token"]}
            status, _, data = request("POST", "/oauth/token", refresh, form=True)
            check(status == 200 and "refresh_token" in json.loads(data), "Refresh rotation failed")
            check(request("POST", "/oauth/token", refresh, form=True)[0] == 400, "Old refresh token reusable")
            refreshed = json.loads(data)
            check(request("POST", "/oauth/revoke", {"client_id": client, "token": refreshed["access_token"]}, form=True)[0] == 200, "Revocation failed")
            check(rpc("tools/list", token=read_token, session=read_session)[0] == 401, "Revoked grant still authenticated")
            check(request("DELETE", "/mcp", token=automation, session=session_b)[0] == 200, "Session deletion failed")
            check(rpc("tools/list", session=session_b)[0] == 404, "Deleted session still usable")
            print("PASS: 502 upstream + 5 cloud tools; legacy/modern native MCP, isolated companies, inputs, files, jobs, OAuth PKCE/refresh/revocation")
        except Exception:
            log.flush()
            print("Native server diagnostics (synthetic test configuration):", file=sys.stderr)
            print((tmp / "server.log").read_text(errors="replace")[-24000:], file=sys.stderr)
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    run(parser.parse_args().binary)
