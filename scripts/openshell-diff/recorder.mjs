// Recording reverse proxy: :3100 → :3000, one JSONL line per client request.
import http from 'node:http';
import fs from 'node:fs';
const out = fs.createWriteStream(process.env.REC_OUT || 'requests.jsonl', { flags: 'a' });
const tag = () => process.env.REC_TAG || '';
http.createServer((req, res) => {
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const headers = {};
    for (let i = 0; i < req.rawHeaders.length; i += 2) headers[req.rawHeaders[i].toLowerCase()] = req.rawHeaders[i + 1];
    out.write(JSON.stringify({ method: req.method, target: req.url, headers, body: body.toString('utf8'), tag: tag() }) + '\n');
    const up = http.request({ host: '127.0.0.1', port: 3000, method: req.method, path: req.url, headers: req.headers }, r => {
      res.writeHead(r.statusCode, r.headers); r.pipe(res);
    });
    up.on('error', e => { res.writeHead(502); res.end(String(e)); });
    up.end(body);
  });
}).listen(3100, () => console.log('recorder on 3100'));
