#!/usr/bin/env python3
"""Loopback-only authenticated sing-box manager UI for singbox-manager.sh."""
import base64
import hashlib
import hmac
import http.cookies
import json
import os
import re
import secrets
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE = Path("/etc/singbox-panel")
AUTH_FILE = BASE / "auth.json"
SESSION_KEY_FILE = BASE / "session.key"
HELPER = "/usr/local/libexec/singbox-panel-helper"
COOKIE = "sbpanel"
SESSION_SECONDS = 12 * 60 * 60
TAG_RE = re.compile(r"^[A-Za-z0-9_-]{1,40}$")

LOGIN_PAGE = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>sing-box 管理登录</title>
<style>body{font:16px system-ui,sans-serif;background:#f3f5f8;color:#19202b;margin:0;display:grid;min-height:100vh;place-items:center}.box{background:white;padding:28px;border-radius:14px;box-shadow:0 8px 30px #19202b18;width:min(360px,calc(100% - 48px))}input,button{box-sizing:border-box;width:100%;padding:12px;margin-top:12px;border:1px solid #ccd3dd;border-radius:8px;font:inherit}button{background:#2458d3;color:white;border:0;cursor:pointer}.err{color:#b42318;min-height:1.4em}</style></head>
<body><main class="box"><h1>sing-box 管理面板</h1><p>请输入安装时生成的面板口令。</p><form method="post" action="/login"><input type="password" name="password" autocomplete="current-password" required autofocus><button type="submit">登录</button></form><p class="err">{{ERROR}}</p></main></body></html>'''

APP_PAGE = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>sing-box 管理面板</title>
<style>
:root{color-scheme:light;--ink:#172033;--muted:#65718a;--line:#e3e8f0;--blue:#2458d3;--bg:#f4f6fa}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px system-ui,-apple-system,"Segoe UI",sans-serif}header{background:#fff;border-bottom:1px solid var(--line);padding:14px max(18px,calc((100% - 1050px)/2));display:flex;justify-content:space-between;align-items:center;gap:12px}main{max-width:1050px;margin:24px auto;padding:0 18px}.row{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px}.card,section{background:#fff;border:1px solid var(--line);border-radius:12px;padding:18px;margin-bottom:16px}.value{font-size:20px;font-weight:650;margin-top:6px}.muted,small{color:var(--muted)}h1{font-size:19px;margin:0}h2{font-size:17px;margin:0 0 14px}button{background:var(--blue);border:0;border-radius:8px;color:#fff;font:inherit;padding:10px 14px;cursor:pointer}button.secondary{background:#edf1f8;color:var(--ink)}button.danger{background:#b42318}.actions{display:flex;gap:8px;flex-wrap:wrap}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:11px 8px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f5f7fa;padding:10px;border-radius:8px;font-size:12px;margin:8px 0 0}.notice{background:#fff8e6;border:1px solid #f2daa0;padding:12px;border-radius:8px;margin:12px 0}.msg{min-height:1.4em;color:var(--muted)}@media(max-width:620px){table,tbody,tr,td{display:block}thead{display:none}tr{border-bottom:1px solid var(--line);padding:8px 0}td{border:0;padding:4px 0}td:before{content:attr(data-label) "：";color:var(--muted);font-weight:600}}
</style></head><body><header><h1>sing-box 管理面板</h1><form method="post" action="/logout"><input type="hidden" name="csrf" value="{{CSRF}}"><button class="secondary" type="submit">退出</button></form></header>
<main><div class="row"><div class="card"><div class="muted">sing-box 服务</div><div id="service" class="value">读取中…</div></div><div class="card"><div class="muted">Tunnel 节点域名</div><div id="nodehost" class="value">—</div><small id="noderoute"></small></div><div class="card"><div class="muted">面板转发域名</div><div id="panelhost" class="value">—</div><small>本机服务：127.0.0.1:8765</small></div></div>
<section><h2>节点</h2><p class="muted">可查看节点分享链接；删除操作会从 sing-box 配置中移除该节点。</p><div style="overflow-x:auto"><table><thead><tr><th>名称</th><th>协议 / 端口</th><th>分享链接</th><th>操作</th></tr></thead><tbody id="nodes"></tbody></table></div><p id="empty" class="muted" hidden>尚无节点。</p></section>
<section><h2>Cloudflare Tunnel 固定域名节点</h2><p>此功能会创建 VLESS + WebSocket 入站，供已配置 Tunnel 的节点域名转发到本机。它不替代 Reality、Hysteria2 或其他现有节点。</p><div class="notice">首次创建后，请确认 Cloudflare Tunnel 的 Published application route 指向 <code>http://127.0.0.1:<span id="wsport">—</span></code>，并为面板域名启用 Cloudflare Access。</div><div class="actions"><button id="addws">创建 Tunnel 节点</button><button class="secondary" id="refresh">刷新状态</button><button class="secondary" id="restart">重启 sing-box</button></div><p id="message" class="msg"></p></section>
<p class="muted">面板仅监听 127.0.0.1，由 cloudflared 转发；不要把管理端口直接暴露到公网。</p></main>
<script nonce="{{NONCE}}">
const csrf=document.querySelector('input[name=csrf]').value;async function api(path,body={}){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify(body)});const j=await r.json();if(!r.ok)throw new Error(j.error||'请求失败');return j}
function td(label,text){const e=document.createElement('td');e.dataset.label=label;e.textContent=text;return e}
async function load(){const r=await fetch('/api/data',{cache:'no-store'});if(!r.ok){location.reload();return}const d=await r.json();document.getElementById('service').textContent=d.service||'未知';document.getElementById('nodehost').textContent=d.node_host||'未配置';document.getElementById('panelhost').textContent=d.panel_host||'未配置';document.getElementById('noderoute').textContent=d.ws_port?'本机服务：127.0.0.1:'+d.ws_port:'';document.getElementById('wsport').textContent=d.ws_port||'—';const body=document.getElementById('nodes');body.replaceChildren();document.getElementById('empty').hidden=!!d.nodes.length;for(const n of d.nodes){const tr=document.createElement('tr');tr.append(td('名称',n.tag),td('协议 / 端口',n.protocol+' / '+n.port));const links=td('分享链接','');const pre=document.createElement('pre');pre.textContent=n.links||'无可生成的链接';links.append(pre);const act=td('操作','');const b=document.createElement('button');b.className='danger';b.textContent='删除';b.onclick=async()=>{if(!confirm('确定删除节点 '+n.tag+'？'))return;try{await api('/api/delete',{tag:n.tag});await load();say('已删除 '+n.tag)}catch(e){say(e.message)}};act.append(b);tr.append(links,act);body.append(tr)}}
function say(s){document.getElementById('message').textContent=s}
document.getElementById('refresh').onclick=()=>load().catch(e=>say(e.message));document.getElementById('restart').onclick=async()=>{try{await api('/api/restart');say('sing-box 已重启');await load()}catch(e){say(e.message)}};document.getElementById('addws').onclick=async()=>{try{await api('/api/add-ws');say('Tunnel 节点已创建');await load()}catch(e){say(e.message)}};load().catch(e=>say(e.message));
</script></body></html>'''


def b64e(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64d(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def atomic_write(path, data, mode=0o640):
    BASE.mkdir(mode=0o750, parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp-" + secrets.token_hex(6))
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def set_password():
    password = sys.stdin.readline().rstrip("\r\n")
    if len(password) < 16 or len(password) > 256:
        print("面板口令长度必须为 16-256 个字符。", file=sys.stderr)
        return 2
    salt = os.urandom(16)
    digest = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=2**14, r=8, p=1, dklen=32)
    payload = {"salt": base64.b64encode(salt).decode(), "hash": base64.b64encode(digest).decode(), "n": 2**14, "r": 8, "p": 1}
    atomic_write(AUTH_FILE, json.dumps(payload).encode() + b"\n")
    return 0


class Handler(BaseHTTPRequestHandler):
    server_version = "SingboxPanel/1.0"
    sys_version = ""
    failures = {}

    def log_message(self, fmt, *args):
        # Do not log request bodies, credentials, cookies, or tokens.
        sys.stderr.write("panel %s - %s\n" % (self.client_address[0], fmt % args))

    def security_headers(self, nonce=""):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cache-Control", "no-store")
        csp = "default-src 'none'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
        csp += "; script-src 'nonce-%s'" % nonce if nonce else "; script-src 'none'"
        self.send_header("Content-Security-Policy", csp)

    def send_bytes(self, status, data, content_type="application/json; charset=utf-8", nonce=""):
        self.send_response(status)
        self.security_headers(nonce)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, status, obj):
        self.send_bytes(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def cookie_secure(self):
        return self.headers.get("X-Forwarded-Proto", "").lower() == "https"

    def set_cookie(self, value, max_age=SESSION_SECONDS):
        attrs = "Path=/; HttpOnly; SameSite=Strict; Max-Age=%d" % max_age
        if self.cookie_secure():
            attrs += "; Secure"
        self.send_header("Set-Cookie", COOKIE + "=" + value + "; " + attrs)

    def read_body(self, max_size=8192):
        raw_len = self.headers.get("Content-Length", "0")
        if not raw_len.isdigit() or int(raw_len) > max_size:
            raise ValueError("请求内容过大")
        raw = self.rfile.read(int(raw_len))
        ctype = self.headers.get("Content-Type", "")
        if "application/json" in ctype:
            return json.loads(raw or b"{}")
        if "application/x-www-form-urlencoded" in ctype:
            from urllib.parse import parse_qs
            return {k: v[-1] for k, v in parse_qs(raw.decode("utf-8"), keep_blank_values=True).items()}
        raise ValueError("不支持的请求格式")

    def password_ok(self, password):
        try:
            data = json.loads(AUTH_FILE.read_text())
            salt = base64.b64decode(data["salt"])
            expected = base64.b64decode(data["hash"])
            actual = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=int(data["n"]), r=int(data["r"]), p=int(data["p"]), dklen=len(expected))
            return hmac.compare_digest(actual, expected)
        except Exception:
            return False

    def make_session(self):
        payload = {"exp": int(time.time()) + SESSION_SECONDS, "csrf": secrets.token_urlsafe(24)}
        raw = json.dumps(payload, separators=(",", ":")).encode()
        key = SESSION_KEY_FILE.read_bytes()
        sig = hmac.new(key, raw, hashlib.sha256).digest()
        return b64e(raw) + "." + b64e(sig), payload

    def session(self):
        try:
            cookies = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
            value = cookies[COOKIE].value
            p, s = value.split(".", 1)
            raw, sig = b64d(p), b64d(s)
            key = SESSION_KEY_FILE.read_bytes()
            if not hmac.compare_digest(sig, hmac.new(key, raw, hashlib.sha256).digest()):
                return None
            payload = json.loads(raw)
            if int(payload["exp"]) < int(time.time()):
                return None
            return payload
        except Exception:
            return None

    def authorized(self, csrf=False, supplied=None):
        payload = self.session()
        if payload is None:
            self.send_json(401, {"error": "登录已过期，请重新登录。"})
            return False
        if csrf:
            supplied = supplied if supplied is not None else self.headers.get("X-CSRF-Token", "")
            if not supplied or not hmac.compare_digest(supplied, payload.get("csrf", "")):
                self.send_json(403, {"error": "安全校验失败，请刷新页面后重试。"})
                return False
        return True

    def call_helper(self, *args):
        try:
            p = subprocess.run(["sudo", "-n", HELPER, *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False)
        except subprocess.TimeoutExpired:
            return False, "管理操作超时。"
        except Exception:
            return False, "无法执行本地管理操作。"
        output = (p.stdout + p.stderr).strip()
        if p.returncode:
            return False, (output or "管理操作失败。")[-1600:]
        return True, output

    def do_GET(self):
        if self.path == "/":
            nonce = secrets.token_urlsafe(18)
            if self.session() is None:
                body = LOGIN_PAGE.replace("{{ERROR}}", "").replace("{{NONCE}}", nonce).encode("utf-8")
                self.send_bytes(200, body, "text/html; charset=utf-8", nonce)
            else:
                payload = self.session()
                body = APP_PAGE.replace("{{CSRF}}", payload["csrf"]).replace("{{NONCE}}", nonce).encode("utf-8")
                self.send_bytes(200, body, "text/html; charset=utf-8", nonce)
            return
        if self.path == "/api/data":
            if not self.authorized():
                return
            ok, output = self.call_helper("data")
            if not ok:
                self.send_json(500, {"error": output})
                return
            try:
                data = json.loads(output)
            except Exception:
                self.send_json(500, {"error": "本地管理数据格式异常。"})
                return
            data["csrf"] = self.session()["csrf"]
            self.send_json(200, data)
            return
        self.send_json(404, {"error": "未找到。"})

    def do_POST(self):
        if self.path == "/login":
            peer = self.client_address[0]
            state = self.failures.get(peer, {"count": 0, "until": 0})
            if state["until"] > time.time():
                self.send_bytes(429, LOGIN_PAGE.replace("{{ERROR}}", "登录暂时被锁定，请稍后重试。").encode(), "text/html; charset=utf-8")
                return
            try:
                data = self.read_body(4096)
                password = str(data.get("password", ""))
            except Exception:
                password = ""
            if not self.password_ok(password):
                state["count"] += 1
                if state["count"] >= 5:
                    state = {"count": 0, "until": time.time() + 900}
                self.failures[peer] = state
                self.send_bytes(401, LOGIN_PAGE.replace("{{ERROR}}", "口令错误。" ).encode(), "text/html; charset=utf-8")
                return
            self.failures.pop(peer, None)
            cookie, _ = self.make_session()
            self.send_response(303)
            self.security_headers()
            self.set_cookie(cookie)
            self.send_header("Location", "/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/logout":
            try:
                form = self.read_body(4096)
            except Exception:
                form = {}
            if not self.authorized(csrf=True, supplied=str(form.get("csrf", ""))):
                return
            ok, output = self.call_helper("logout")
            if not ok:
                self.send_json(500, {"error": output})
                return
            self.send_response(303)
            self.security_headers()
            self.set_cookie("", 0)
            self.send_header("Location", "/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path.startswith("/api/"):
            if not self.authorized(csrf=True):
                return
            try:
                data = self.read_body()
            except Exception as e:
                self.send_json(400, {"error": str(e)})
                return
            action = self.path
            if action == "/api/restart":
                cmd = ("restart",)
            elif action == "/api/add-ws":
                cmd = ("add-ws",)
            elif action == "/api/delete":
                tag = str(data.get("tag", ""))
                if not TAG_RE.fullmatch(tag):
                    self.send_json(400, {"error": "节点名称格式不正确。"})
                    return
                cmd = ("delete", tag)
            else:
                self.send_json(404, {"error": "未找到。"})
                return
            ok, output = self.call_helper(*cmd)
            if not ok:
                self.send_json(400, {"error": output})
            else:
                self.send_json(200, {"ok": True, "message": output})
            return
        self.send_json(404, {"error": "未找到。"})


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--set-password":
        return set_password()
    host = "127.0.0.1"
    port = 8765
    for i, arg in enumerate(sys.argv[:-1]):
        if arg == "--port":
            port = int(sys.argv[i + 1])
        elif arg == "--host":
            host = sys.argv[i + 1]
    if host != "127.0.0.1" or not (1 <= port <= 65535):
        print("面板必须绑定 127.0.0.1。", file=sys.stderr)
        return 2
    if not AUTH_FILE.is_file() or not SESSION_KEY_FILE.is_file():
        print("面板认证文件缺失，请运行 sb panel install。", file=sys.stderr)
        return 1
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
