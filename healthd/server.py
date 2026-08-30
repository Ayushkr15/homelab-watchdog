import http.client, json, os, socket, time
from urllib.parse import urlparse, parse_qs

AUTH = os.environ.get("AUTH_TOKEN", "")
CRIT = set(s.strip() for s in os.environ.get("CRITICAL_SERVICES", "").split(",") if s.strip())
SOCK = "/var/run/docker.sock"

def docker_containers():
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCK)
    conn = http.client.HTTPConnection("localhost")
    conn.sock = sock
    conn.request("GET", "/containers/json?all=1")
    resp = conn.getresponse()
    body = resp.read()
    conn.close()
    if resp.status != 200:
        return None, "docker api http %d" % resp.status
    return json.loads(body), None

def evaluate():
    try:
        conts, err = docker_containers()
    except Exception as e:
        return {"ok": False, "error": "docker_unreachable", "detail": str(e)}
    if err:
        return {"ok": False, "error": "docker_unreachable", "detail": err}
    down, critical_down, total = [], [], 0
    for c in conts:
        name = c.get("Names", [""])[0].lstrip("/")
        if not name:
            continue
        total += 1
        state = c.get("State", "?")
        health = (c.get("Health") or {}).get("Status") if c.get("Health") else None
        is_down = state != "running" or health == "unhealthy"
        if is_down:
            down.append(name)
            if name in CRIT:
                critical_down.append(name)
    return {"ok": len(down) == 0, "total": total, "up": total - len(down),
            "down": down, "critical_down": critical_down,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}

from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        q = parse_qs(parsed.query)
        token = q.get("token", [""])[0]
        if not AUTH or token != AUTH:
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":false,"error":"unauthorized"}')
            return
        if parsed.path != "/healthz":
            self.send_response(404)
            self.end_headers()
            return
        data = evaluate()
        body = json.dumps(data).encode()
        if not data["ok"] and data.get("error") == "docker_unreachable":
            self.send_response(500)
        elif not data["ok"]:
            self.send_response(503)
        else:
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 8085), H).serve_forever()