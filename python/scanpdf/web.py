#!/usr/bin/env python3
"""Phone entry point: a tiny LAN web front-end for the cleanup engine.

The engine is Python on this Mac, so the honest way to use it from an iPhone
tonight is Safari against this server rather than an unsigned app. A random
token in the URL keeps casual LAN visitors out; anyone with the link can use
it, so stop the agent when you don't need it.

    scanpdf-web            start in foreground
    install_web.sh         install as a LaunchAgent (runs at login)
"""
import html
import io
import json
import os
import secrets
import sys
import atexit
import subprocess
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine  # noqa: E402

PORT = 8787
TOKEN = os.environ.get("SCANPDF_TOKEN") or secrets.token_urlsafe(9)
OUTDIR = os.path.expanduser("~/Documents/扫描件清晰化/已处理")
os.makedirs(OUTDIR, exist_ok=True)

PAGE = """<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>试卷扫描清晰化</title><style>
:root{color-scheme:light dark}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;font:16px/1.5 -apple-system,"PingFang SC",sans-serif;
 background:var(--bg,#f2f2f7);color:var(--fg,#111);padding:20px 16px 40px}
@media (prefers-color-scheme:dark){body{--bg:#000;--fg:#f2f2f7}}
.card{background:var(--card,#fff);border-radius:18px;padding:22px;
 box-shadow:0 1px 3px rgba(0,0,0,.08)}
@media (prefers-color-scheme:dark){.card{--card:#1c1c1e}}
h1{font-size:20px;margin:0 0 4px}
p.sub{margin:0 0 18px;color:#8e8e93;font-size:13px}
#drop{border:1.5px dashed #0a84ff;border-radius:16px;background:rgba(10,132,255,.07);
 padding:34px 16px;text-align:center;color:#0a84ff;font-weight:600}
#drop.on{background:rgba(10,132,255,.18)}
input[type=file]{display:none}
button{margin-top:14px;width:100%;border:0;border-radius:12px;padding:14px;
 font-size:16px;font-weight:600;background:#0a84ff;color:#fff}
button:disabled{background:#8e8e93}
#log{margin-top:16px;font-size:13px;color:#8e8e93;white-space:pre-wrap;min-height:20px}
a.dl{display:block;margin-top:14px;text-align:center;text-decoration:none;
 background:#30d158;color:#fff;border-radius:12px;padding:14px;font-weight:600}
</style></head><body>
<div class="card">
 <h1>试卷扫描清晰化</h1>
 <p class="sub">扫描 / 拍照的试卷 → 可直接打印的 A4 清晰版</p>
 <label id="drop">点选择 PDF，或从微信/文件拖进来<input id="f" type="file" accept="application/pdf" multiple></label>
 <button id="go" disabled>开始处理</button>
 <div id="log"></div>
 <div id="out"></div>
</div>
<script>
const drop=document.getElementById('drop'),f=document.getElementById('f'),
 go=document.getElementById('go'),log=document.getElementById('log'),out=document.getElementById('out');
let files=[];
const show=()=>{go.disabled=!files.length;
 drop.firstChild.textContent=files.length?files.map(x=>x.name).join('、'):'点选择 PDF，或从微信/文件拖进来';};
f.onchange=()=>{files=[...f.files];show()};
['dragenter','dragover'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.add('on')}));
['dragleave','drop'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.remove('on')}));
drop.addEventListener('drop',ev=>{files=[...ev.dataTransfer.files].filter(x=>x.name.endsWith('.pdf'));show()});
go.onclick=async()=>{
 go.disabled=true;out.innerHTML='';log.textContent='上传中…';
 const fd=new FormData();files.forEach(x=>fd.append('files',x));
 const r=await fetch('?t=__TOKEN__&upload=1',{method:'POST',body:fd});
 const j=await r.json();
 log.textContent=j.log||'';
 if(j.results)for(const it of j.results){
   const a=document.createElement('a');a.className='dl';a.href='?t=__TOKEN__&get='+it.id;
   a.download=it.name;a.textContent='下载 '+it.name;out.appendChild(a);}
 if(j.error){log.textContent='失败：'+j.error;go.disabled=false;}
};
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _ok(self, body, ctype="application/json; charset=utf-8", code=200):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authed(self):
        q = parse_qs(urlparse(self.path).query)
        return (q.get("t") or [""])[0] == TOKEN

    def do_GET(self):
        q = parse_qs(urlparse(self.path).query)
        if not self._authed():
            return self._ok("403", "text/plain; charset=utf-8", 403)
        gid = (q.get("get") or [""])[0]
        if gid:
            path = os.path.join(OUTDIR, RESULTS.get(gid, ""))
            if not os.path.isfile(path):
                return self._ok("404", "text/plain", 404)
            data = open(path, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "application/pdf")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Content-Disposition",
                             f'attachment; filename="{os.path.basename(path)}"')
            self.end_headers()
            return self.wfile.write(data)
        self._ok(PAGE.replace("__TOKEN__", html.escape(TOKEN)), "text/html; charset=utf-8")

    def do_POST(self):
        if not self._authed():
            return self._ok("403", "text/plain; charset=utf-8", 403)
        length = int(self.headers.get("Content-Length", 0))
        ctype = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in ctype or length > 200 * 1024 * 1024:
            return self._ok(json.dumps({"error": "只接受 200MB 以内的 PDF 上传"}))
        boundary = ctype.split("boundary=")[-1].encode()
        raw = self.rfile.read(length)
        results, logs = [], []
        for part in raw.split(b"--" + boundary):
            if b"filename=\"" not in part:
                continue
            head, _, body = part.partition(b"\r\n\r\n")
            name = head.split(b"filename=\"")[1].split(b"\"")[0].decode("utf-8", "replace")
            if not name.lower().endswith(".pdf"):
                logs.append(f"跳过非 PDF：{name}")
                continue
            tmp = os.path.join(OUTDIR, f".upload-{uuid.uuid4().hex}.pdf")
            with open(tmp, "wb") as fh:
                fh.write(body.rstrip(b"\r\n"))
            dst = os.path.join(OUTDIR, os.path.splitext(name)[0] + "-清晰版.pdf")
            try:
                res = engine.process_pdf(tmp, dst, overwrite=True)
                if res.get("status") != "ok":
                    logs.append(f"{name}：{res.get('detail', '无需处理')}")
                    os.remove(dst) if os.path.exists(dst) else None
                    continue
                rid = uuid.uuid4().hex
                RESULTS[rid] = os.path.basename(dst)
                results.append({"id": rid, "name": os.path.basename(dst)})
                logs.append(f"{name} → {res['pages']} 页 A4，"
                            f"纸面 {res['sheet_width_mm']}mm，{res['seconds']}s")
            except SystemExit as e:
                logs.append(f"{name}：{e}")
            finally:
                os.path.exists(tmp) and os.remove(tmp)
        self._ok(json.dumps({"results": results, "log": "\n".join(logs)},
                            ensure_ascii=False))


RESULTS = {}


def main():
    ip = "0.0.0.0"
    srv = ThreadingHTTPServer((ip, PORT), Handler)
    lan = ""
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80)); lan = s.getsockname()[0]; s.close()
    except OSError:
        pass
    url = f"http://{lan}:{PORT}/?t={TOKEN}"
    print(f"手机入口：{url}")
    # Advertise on Bonjour so the iOS app can find this Mac without typing an
    # address. dns-sd ships with macOS; the token rides in the TXT record.
    try:
        bonjour = subprocess.Popen(
            ["dns-sd", "-R", "scanpdf", "_scanpdf._tcp", "local", str(PORT),
             f"token={TOKEN}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atexit.register(bonjour.terminate)
    except OSError:
        pass
    with open(os.path.expanduser("~/Documents/扫描件清晰化/手机入口.txt"), "w") as fh:
        fh.write(url + "\n")
    threading.Timer(60 * 60 * 12, lambda: None).start()
    srv.serve_forever()


if __name__ == "__main__":
    main()
