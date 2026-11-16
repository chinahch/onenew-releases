const REPOSITORY = 'chinahch/onenew-releases';
const HEADERS = {'Content-Type':'text/plain; charset=utf-8', 'X-Content-Type-Options':'nosniff', 'Cache-Control':'no-store'};
function error(status, message) { return new Response(message + '\n', {status, headers:HEADERS}); }
async function boundedText(body, limit) {
  const reader=body.getReader(); const chunks=[]; let size=0;
  for (;;) {
    const {done,value}=await reader.read(); if(done) break;
    size+=value.length;
    if(size>limit) { await reader.cancel(); throw new Error('Oversized metadata'); }
    chunks.push(value);
  }
  const bytes=new Uint8Array(size); let offset=0;
  for(const chunk of chunks) { bytes.set(chunk,offset); offset+=chunk.length; }
  return new TextDecoder().decode(bytes);
}
async function artifactBody(response, filename) {
  if (/html/i.test(response.headers.get('Content-Type') || '') || !response.body) {
    await response.body?.cancel(); throw new Error('Invalid artifact');
  }
  if (!filename.endsWith('.tar.gz')) {
    const text=await boundedText(response.body,65536);
    if(filename.startsWith('SHA256SUMS-')) {
      const arch=filename.slice('SHA256SUMS-'.length);
      const expected=new RegExp('^[0-9a-f]{64}  onenew-node-linux-'+arch+'\\.tar\\.gz\\n?$');
      if(!expected.test(text)) throw new Error('Invalid checksum');
    } else {
      const info=JSON.parse(text);
      if(!info || typeof info!=='object' || Array.isArray(info)) throw new Error('Invalid build metadata');
    }
    return text;
  }
  const reader=response.body.getReader(); const initial=[]; let size=0;
  while(size<2) { const next=await reader.read(); if(next.done) break; initial.push(next.value); size+=next.value.length; }
  const prefix=initial.flatMap(chunk=>Array.from(chunk.subarray(0,2))).slice(0,2);
  if(prefix[0]!==31 || prefix[1]!==139) { await reader.cancel(); throw new Error('Invalid gzip'); }
  return new ReadableStream({
    start(controller) { for(const chunk of initial) controller.enqueue(chunk); },
    async pull(controller) { const next=await reader.read(); if(next.done) controller.close(); else controller.enqueue(next.value); },
    cancel(reason) { return reader.cancel(reason); }
  });
}

// Fixed destinations only. No client-supplied origin, credentials or request headers.
export function createHandler(upstream = fetch) {
  return async function handle(request, env) {
    const url = new URL(request.url);
    if (request.method !== 'GET' && request.method !== 'HEAD') return error(405, 'GET or HEAD required');
    if (url.search) return error(400, 'Query parameters are not accepted');
    const head = request.method === 'HEAD';
    try {
      if (url.pathname === '/health') return new Response(head ? null : 'onenew distribution ready\n', {headers:HEADERS});
      if (['/install','/upgrade'].includes(url.pathname)) {
        const asset = await env.ASSETS.fetch(new Request('https://assets.local/install.sh'));
        if (!asset.ok) return error(502, 'Installer unavailable');
        let script = await asset.text();
        if (!script.startsWith('#!/usr/bin/env bash\n')) return error(502, 'Invalid installer asset');
        if (url.pathname === '/upgrade') script = script.replace('\n', '\nset -- --upgrade "$@"\n');
        return new Response(head ? null : script, {headers:HEADERS});
      }
      const match = /^\/releases\/(node-v\d+\.\d+\.\d+)\/(onenew-node-linux-(?:amd64|arm64)\.tar\.gz|SHA256SUMS-(?:amd64|arm64)|build-info-(?:amd64|arm64)\.json)$/.exec(url.pathname);
      if (!match) return error(404, 'Not found');
      const response = await upstream(`https://github.com/${REPOSITORY}/releases/download/${match[1]}/${match[2]}`, {
        method:head ? 'HEAD' : 'GET', redirect:'follow', signal:AbortSignal.timeout(30000),
        headers:{'User-Agent':'onenew-distribution'}
      });
      if (response.status !== 200) { await response.body?.cancel(); return error(502, 'Release asset unavailable'); }
      const headers = new Headers({
        'Content-Type':match[2].endsWith('.tar.gz') ? 'application/gzip' : 'text/plain; charset=utf-8',
        'X-Content-Type-Options':'nosniff', 'Cache-Control':'public, max-age=300'
      });
      // Never propagate Location, Set-Cookie, or arbitrary upstream headers.
      const body=head ? null : await artifactBody(response,match[2]);
      return new Response(body, {headers});
    } catch { return error(502, 'Distribution service unavailable'); }
  };
}
export default {fetch:createHandler()};
