import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import { createHandler } from '../worker.mjs';

const origin = 'https://get.timi.baby';
function fixture(reply = new Response(new Uint8Array([31,139,8,0]))) {
  const calls = [];
  const handler = createHandler(async (url, init) => { calls.push({url, init}); return reply; },(name,env)=>env.ASSETS.fetch(new Request('https://assets.local/'+name)));
  const env = {ASSETS: {fetch: async () => new Response('#!/usr/bin/env bash\necho fixture\n')}};
  return {calls, env, request: (path, init) => handler(new Request(origin + path, init), env)};
}
test('install and upgrade are shell scripts; upgrade inserts flag', async () => {
  const f = fixture();
  const install = await f.request('/install');
  assert.equal(install.status, 200);
  assert.match(install.headers.get('content-type'), /text\/plain/);
  assert.match(await install.text(), /^#!\/usr\/bin\/env bash/);
  assert.match(await (await f.request('/upgrade')).text(), /set -- --upgrade "\$@"/);
  assert.equal(f.calls.length, 0);
});
test('only explicit release assets are proxied without incoming credentials', async () => {
  const f = fixture();
  const result = await f.request('/releases/node-v0.1.10/onenew-node-linux-amd64.tar.gz', {headers:{Authorization:'private',Cookie:'private'}});
  assert.equal(result.status, 200);
  assert.equal(f.calls[0].url, 'https://github.com/chinahch/onenew-releases/releases/download/node-v0.1.10/onenew-node-linux-amd64.tar.gz');
  assert.equal(JSON.stringify(f.calls).includes('private'), false);
  assert.equal(result.headers.get('location'), null);
});
test('short entry downloads complete installer and checks hash before privileged execution',async()=>{
 const f=fixture();const text=await(await f.request('/install')).text();
 assert.match(text,/https:\/\/get\.timi\.baby\/node\/install\.sh/);
 assert.ok(text.indexOf('sha256sum -c')<text.indexOf('sudo -n bash'));
 assert.match(text,/sudo -v <\/dev\/tty/);
 const full=await(await f.request('/node/install.sh')).text();
 assert.equal(full,'#!/usr/bin/env bash\necho fixture\n');
});
test('unknown paths, query strings and non-GET methods never reach upstream', async () => {
  const f = fixture();
  for (const path of ['/install?token=secret','/proxy?url=https://example.test','/releases/latest/other.zip','/releases/node-v0.1.10/private.json','/releases/node-v0.1.10/../../source.tar.gz']) {
    assert.notEqual((await f.request(path)).status, 200);
  }
  assert.equal((await f.request('/install', {method:'POST'})).status, 405);
  assert.equal(f.calls.length, 0);
});
test('upstream failure returns non-executable plain text and no cache', async () => {
  const f = fixture(new Response('<html>private upstream error</html>', {status:404}));
  const result = await f.request('/releases/node-v0.1.10/SHA256SUMS-amd64');
  assert.equal(result.status, 502);
  assert.equal(result.headers.get('cache-control'), 'no-store');
  assert.equal((await result.text()).includes('private upstream'), false);
});
test('broken script asset cannot be returned as a successful installer', async () => {
  const f = fixture();
  f.env.ASSETS.fetch = async () => new Response('<html>missing</html>');
  assert.equal((await f.request('/install')).status, 502);
});
test('Windows checkout CRLF is normalized before serving Bash', async () => {
  const f=fixture();
  f.env.ASSETS.fetch=async()=>new Response('#!/usr/bin/env bash\r\nset -eu\r\necho ok\r\n');
  for(const path of ['/install','/upgrade']) {
    const result=await f.request(path);
    assert.equal(result.status,200);
    const text=await result.text();
    assert.equal(text.includes('\r'),false);
    assert.match(text,/^#!\/usr\/bin\/env bash\n/);
  }
});
test('HTTP 200 HTML or invalid binary is not returned as a release', async () => {
  for (const response of [new Response('<html>error</html>',{headers:{'Content-Type':'text/html'}}), new Response('error',{headers:{'Content-Type':'application/octet-stream'}})]) {
    const f=fixture(response);
    assert.equal((await f.request('/releases/node-v0.1.10/onenew-node-linux-amd64.tar.gz')).status,502);
  }
});
test('checksum contents must name the expected architecture artifact', async () => {
  const valid='a'.repeat(64)+'  onenew-node-linux-amd64.tar.gz\n';
  assert.equal((await fixture(new Response(valid)).request('/releases/node-v0.1.10/SHA256SUMS-amd64')).status,200);
  assert.equal((await fixture(new Response(valid.replace('amd64','arm64'))).request('/releases/node-v0.1.10/SHA256SUMS-amd64')).status,502);
});
test('panel scripts have separate fixed raw routes and do not receive node upgrade flag',async()=>{
 const f=fixture();
 for(const name of ['upgrade','restore']) {
  const text=await(await f.request('/panel/'+name)).text();
  assert.ok(text.includes('https://get.timi.baby/scripts/panel-'+name+'.sh'));
  assert.ok(!text.includes('set -- --upgrade'));
  assert.equal((await f.request('/scripts/panel-'+name+'.sh')).status,200);
 }
 assert.equal((await f.request('/scripts/private-source.tar.gz')).status,404);
});
test('actual bootstrap preserves token stdin and refuses a corrupted installer before execution',async()=>{
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),'onenew-bootstrap-'));
 const installer='#!/usr/bin/env bash\nIFS= read -r token\n[ "$token" = fixture-token ] || exit 55\nprintf ran > "$TEST_MARKER"\n';
 const f=fixture();f.env.ASSETS.fetch=async()=>new Response(installer);
 fs.mkdirSync(path.join(temp,'bin'));
 fs.writeFileSync(path.join(temp,'bootstrap.sh'),await(await f.request('/install')).text());
 fs.writeFileSync(path.join(temp,'installer.sh'),installer);
 fs.writeFileSync(path.join(temp,'bin','id'),'#!/bin/sh\necho 0\n',{mode:0o755});
 fs.writeFileSync(path.join(temp,'bin','curl'),'#!/bin/bash\nwhile [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then out=$2;shift 2;else shift;fi;done\nif [ "$CORRUPT" = 1 ]; then printf corrupt > "$out";else cp "$FIXTURE_INSTALLER" "$out";fi\n',{mode:0o755});
 const posix=p=>process.platform==='win32'?'/'+p[0].toLowerCase()+p.slice(2).replaceAll('\\','/'):p;
 try {
  for(const corrupt of ['1','0']) {
   const result=spawnSync(process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'bash',['-c','export PATH="$MOCK_BIN:$PATH"; exec bash "$BOOTSTRAP"'],{input:'fixture-token\n',encoding:'utf8',env:{...process.env,MOCK_BIN:posix(path.join(temp,'bin')),BOOTSTRAP:path.join(temp,'bootstrap.sh').replaceAll('\\','/'),FIXTURE_INSTALLER:path.join(temp,'installer.sh').replaceAll('\\','/'),TEST_MARKER:path.join(temp,'marker').replaceAll('\\','/'),CORRUPT:corrupt}});
   if(corrupt==='1'){assert.notEqual(result.status,0);assert.equal(fs.existsSync(path.join(temp,'marker')),false)}
   else{assert.equal(result.status,0,result.stderr);assert.equal(fs.readFileSync(path.join(temp,'marker'),'utf8'),'ran')}
  }
 } finally {
  assert.ok(path.resolve(temp).startsWith(path.resolve(os.tmpdir())+path.sep));
  fs.rmSync(temp,{recursive:true,force:true});
 }
});
