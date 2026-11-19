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
async function artifactBody(response, filename, expectedLength, partial = false) {
  if (/html/i.test(response.headers.get('Content-Type') || '') || !response.body) {
    await response.body?.cancel(); throw new Error('Invalid artifact');
  }
  const executable=filename.startsWith('caddy-updater-linux-');
  if (!filename.endsWith('.tar.gz') && !executable) {
    const text=await boundedText(response.body,65536);
    if(filename.startsWith('SHA256SUMS-')) {
      const suffix=filename.slice('SHA256SUMS-'.length);
      const name=suffix==='source'?'onenew-node-source.tar.gz':suffix.startsWith('updater-')?'caddy-updater-linux-'+suffix.slice(8):'onenew-node-linux-'+suffix+'.tar.gz';
      const expected=new RegExp('^[0-9a-f]{64}  '+name.replaceAll('.','\\.')+'\\n?$');
      if(!expected.test(text)) throw new Error('Invalid checksum');
    } else {
      const info=JSON.parse(text);
      if(!info || typeof info!=='object' || Array.isArray(info)) throw new Error('Invalid build metadata');
    }
    return text;
  }
  const reader=response.body.getReader(); const initial=[]; let size=0;
  const needed=partial?0:executable?4:2;
  while(size<needed) { const next=await reader.read(); if(next.done) break; initial.push(next.value); size+=next.value.length; }
  const prefix=initial.flatMap(chunk=>Array.from(chunk.subarray(0,needed))).slice(0,needed);
  const magic=executable?[127,69,76,70]:[31,139];
  if(!partial && magic.some((byte,index)=>prefix[index]!==byte)) { await reader.cancel(); throw new Error('Invalid binary'); }
  return new ReadableStream({
    start(controller) { for(const chunk of initial) controller.enqueue(chunk); },
    async pull(controller) { const next=await reader.read(); if(next.done) { if(expectedLength && size!==expectedLength) controller.error(new Error('Truncated release asset')); else controller.close(); } else { size+=next.value.length; controller.enqueue(next.value); } },
    cancel(reason) { return reader.cancel(reason); }
  });
}

// Fixed destinations only. No client-supplied origin, credentials or request headers.
export function createHandler(upstream = fetch, scriptLoader = null) {
  return async function handle(request, env) {
    const url = new URL(request.url);
    if (request.method !== 'GET' && request.method !== 'HEAD') return error(405, 'GET or HEAD required');
    if (url.search) return error(400, 'Query parameters are not accepted');
    const head = request.method === 'HEAD';
    try {
      if (url.pathname === '/health') return new Response(head ? null : 'onenew distribution ready\n', {headers:HEADERS});
      const scriptAssets = {
        '/install':['install.sh','/node/install.sh'], '/upgrade':['install.sh','/node/install.sh'], '/node/install.sh':['install.sh',null],
        '/panel/upgrade':['panel-upgrade.sh','/scripts/panel-upgrade.sh'], '/scripts/panel-upgrade.sh':['panel-upgrade.sh',null],
        '/panel/restore':['panel-restore.sh','/scripts/panel-restore.sh'], '/scripts/panel-restore.sh':['panel-restore.sh',null]
      };
      if (Object.hasOwn(scriptAssets,url.pathname)) {
        const [name,rawPath]=scriptAssets[url.pathname];
        // Public scripts are independent of private panel source. Fetch the latest
        // published copy so node upgrades do not require another Worker deployment.
        const asset = scriptLoader ? await scriptLoader(name,env) : await upstream(
          'https://raw.githubusercontent.com/'+REPOSITORY+'/main/assets/'+name,
          {headers:{'User-Agent':'onenew-distribution'},signal:AbortSignal.timeout(15000),cf:{cacheTtl:60}}
        );
        if (!asset.ok) return error(502, 'Installer unavailable');
        // Windows Git checkouts may use CRLF; Bash delivery must always use LF.
        let script = (await asset.text()).replace(/\r\n/g, '\n');
        if (!script.startsWith('#!/usr/bin/env bash\n')) return error(502, 'Invalid installer asset');
        if (rawPath) {
          const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(script))),b=>b.toString(16).padStart(2,'0')).join('');
          script=`#!/usr/bin/env bash
set -euo pipefail
umask 077
${url.pathname==='/upgrade'?'set -- --upgrade "$@"\n':''}f=$(mktemp) || exit
trap 'rm -f -- "$f"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL https://get.timi.baby${rawPath} -o "$f"
printf '%s  %s\\n' '${hash}' "$f" | sha256sum -c - >/dev/null
if [ "$(id -u)" = 0 ]; then
  bash "$f" "$@"
else
  sudo -v </dev/tty
  sudo -n bash "$f" "$@"
fi
`;
        }
        return new Response(head ? null : script, {headers:HEADERS});
      }
      const match = /^\/releases\/(node-v\d+\.\d+\.\d+)\/(onenew-node-linux-(?:amd64|arm64)\.tar\.gz|onenew-node-source\.tar\.gz|caddy-updater-linux-(?:amd64|arm64)|SHA256SUMS-(?:(?:updater-)?(?:amd64|arm64)|source)|build-info-(?:amd64|arm64)\.json)$/.exec(url.pathname);
      if (!match) return error(404, 'Not found');
      const binary = match[2].endsWith('.tar.gz') || match[2].startsWith('caddy-updater-linux-');
      const range = binary && !head ? request.headers.get('Range') : null;
      const bounds = range === null ? null : /^bytes=(\d{1,10})-(\d{0,10})$/.exec(range);
      if (range !== null && (!bounds || (bounds[2] && Number(bounds[1]) > Number(bounds[2])))) {
        return error(400, 'Expected one byte range with an explicit start');
      }
      const upstreamHeaders = {'User-Agent':'onenew-distribution'};
      if (bounds) upstreamHeaders.Range = range;
      const response = await upstream(`https://github.com/${REPOSITORY}/releases/download/${match[1]}/${match[2]}`, {
        method:head ? 'HEAD' : 'GET', redirect:'follow', signal:AbortSignal.timeout(900000),
        headers:upstreamHeaders
      });
      if (bounds && response.status === 416) {
        await response.body?.cancel();
        const headers = new Headers(HEADERS);
        const contentRange = response.headers.get('Content-Range');
        if (/^bytes \*\/\d{1,10}$/.test(contentRange||'')) headers.set('Content-Range',contentRange);
        return new Response('Range not satisfiable\n',{status:416,headers});
      }
      const partial = Boolean(bounds && response.status === 206);
      if (response.status !== 200 && !partial) { await response.body?.cancel(); return error(502, 'Release asset unavailable'); }
      const headers = new Headers({
        'Content-Type':match[2].endsWith('.tar.gz') ? 'application/gzip' : match[2].startsWith('caddy-updater-linux-') ? 'application/octet-stream' : 'text/plain; charset=utf-8',
        'X-Content-Type-Options':'nosniff', 'Cache-Control':'public, max-age=300'
      });
      let length = Number(response.headers.get('Content-Length')) || 0;
      if (partial) {
        const contentRange = response.headers.get('Content-Range');
        const parts = /^bytes (\d{1,10})-(\d{1,10})\/(\d{1,10})$/.exec(contentRange||'');
        const [start,end,total] = parts ? parts.slice(1).map(Number) : [];
        const expectedEnd = bounds[2] ? Math.min(Number(bounds[2]),total-1) : total-1;
        if (!parts || start !== Number(bounds[1]) || end < start || end !== expectedEnd || (length && length !== end-start+1)) {
          await response.body?.cancel();
          return error(502, 'Invalid upstream byte range');
        }
        length = end-start+1;
        headers.set('Content-Range',contentRange);
        headers.set('Cache-Control','no-store');
      }
      if(binary && Number.isSafeInteger(length) && length>0) headers.set('Content-Length',String(length));
      // Never propagate Location, Set-Cookie, or arbitrary upstream headers.
      const body=head ? null : await artifactBody(response,match[2],length,partial);
      return new Response(body, {status:partial?206:200,headers});
    } catch { return error(502, 'Distribution service unavailable'); }
  };
}
export default {fetch:createHandler()};
