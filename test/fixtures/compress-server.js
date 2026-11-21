const http = require("http"), zlib = require("zlib"), crypto = require("crypto");
const big = Array.from({ length: 3000 }, (_, i) => "line " + i + " of some text\n").join("");
const srv = http.createServer((req, res) => {
  const u = req.url.split("?")[0];
  if (u === "/big") { res.setHeader("content-type", "text/plain"); return res.end(big); }
  if (u === "/own") {   // an app that compresses by itself
    res.writeHead(200, { "content-type": "text/plain", "content-encoding": "gzip", vary: "Accept-Encoding" });
    return res.end(zlib.gzipSync(big));
  }
  if (u === "/sse") {   // four events, 400 ms apart; the first one at once
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    let n = 0; res.write("data: 0\n\n");
    const t = setInterval(() => { n++; res.write("data: " + n + "\n\n"); if (n === 3) { clearInterval(t); res.end(); } }, 400);
    return;
  }
  res.setHeader("content-type", "text/plain"); res.end("ok\n");
});
srv.on("upgrade", (req, sock) => {   // a websocket handshake, then five bytes
  const acc = crypto.createHash("sha1").update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  sock.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + acc + "\r\n\r\nws-ok");
  setTimeout(() => sock.end(), 300);
});
srv.listen(process.env.PORT, "127.0.0.1");
