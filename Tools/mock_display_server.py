#!/usr/bin/env python3
"""
Mock of move-anything's display_server.c (Display Mirror) for testing without a Move.

Same protocol as the real server:
  GET /        -> HTML page with <canvas width=128 height=64> and an EventSource('/stream') client
  GET /stream  -> Server-Sent Events, each event = base64 of 1024 bytes
                  (SSD1306 layout: 8 pages x 128 columns, bit n of a byte = row page*8+n)

Usage: python3 Tools/mock_display_server.py [port]   (default 7681)
"""
import base64, math, socketserver, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = b"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Move Display (mock)</title>
<style>body{background:#111;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh}
canvas{image-rendering:pixelated;width:512px;height:256px;border:2px solid #333}
#status{color:#888;font:12px monospace;margin-top:8px}</style></head><body>
<canvas id="c" width="128" height="64"></canvas><div id="status">connecting...</div>
<script>
const canvas=document.getElementById('c'),ctx=canvas.getContext('2d'),statusEl=document.getElementById('status');
const img=ctx.createImageData(128,64);let frames=0,lastFrame=Date.now();
function connect(){const es=new EventSource('/stream');
es.onopen=()=>{statusEl.textContent='connected';};
es.onerror=()=>{statusEl.textContent='disconnected - reconnecting...';};
es.onmessage=(e)=>{const raw=atob(e.data),d=img.data;
for(let page=0;page<8;page++)for(let col=0;col<128;col++){const b=raw.charCodeAt(page*128+col);
for(let bit=0;bit<8;bit++){const y=page*8+bit,idx=(y*128+col)*4,on=(b>>bit)&1;d[idx]=d[idx+1]=d[idx+2]=on?255:0;d[idx+3]=255;}}
ctx.putImageData(img,0,0);frames++;const now=Date.now();
if(now-lastFrame>1000){statusEl.textContent='connected - '+frames+' fps';frames=0;lastFrame=now;}};}
connect();
</script></body></html>"""

def frame(t):
    px = [[0] * 128 for _ in range(64)]
    # border
    for x in range(128): px[0][x] = px[63][x] = 1
    for y in range(64): px[y][0] = px[y][127] = 1
    # moving sine wave
    for x in range(128):
        y = int(32 + 20 * math.sin(x / 10.0 + t * 3))
        px[max(1, min(62, y))][x] = 1
    # bouncing block
    bx = int(64 + 50 * math.sin(t * 1.3))
    for y in range(6, 14):
        for x in range(bx - 4, bx + 4):
            if 1 <= x < 127: px[y][x] = 1
    out = bytearray(1024)
    for page in range(8):
        for col in range(128):
            b = 0
            for bit in range(8):
                if px[page * 8 + bit][col]: b |= 1 << bit
            out[page * 128 + col] = b
    return bytes(out)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            print("SSE client connected", flush=True)
            try:
                t0 = time.time()
                while True:
                    data = base64.b64encode(frame(time.time() - t0))
                    self.wfile.write(b"data: " + data + b"\n\n")
                    self.wfile.flush()
                    time.sleep(1 / 30)
            except (BrokenPipeError, ConnectionResetError):
                print("SSE client disconnected", flush=True)
        elif self.path in ("/", "/index", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(PAGE)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(PAGE)
        else:
            self.send_error(404)

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7681
    ThreadingHTTPServer.daemon_threads = True
    print(f"mock display server on http://localhost:{port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
