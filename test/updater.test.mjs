import test from 'node:test';
import assert from 'node:assert/strict';
import {createHandler} from '../worker.mjs';
const base='https://get.timi.baby/releases/node-v0.1.12/';
function request(name,response){return createHandler(async()=>response)(new Request(base+name),{});}
test('official updater assets and matching checksums are supported',async()=>{
 for(const arch of ['amd64','arm64']){
  const name='caddy-updater-linux-'+arch;
  const result=await request(name,new Response(new Uint8Array([127,69,76,70,1])));
  assert.equal(result.status,200);assert.equal(result.headers.get('content-type'),'application/octet-stream');
  assert.deepEqual(new Uint8Array(await result.arrayBuffer()),new Uint8Array([127,69,76,70,1]));
  assert.equal((await request('SHA256SUMS-updater-'+arch,new Response('a'.repeat(64)+'  '+name+'\n'))).status,200);
  assert.equal((await request(name,new Response('not-ELF'))).status,502);
 }
});
test('binary streaming preserves length and detects truncated successful responses',async()=>{
 const name='onenew-node-linux-amd64.tar.gz';
 const response=await request(name,new Response(new Uint8Array([31,139,8,0]),{headers:{'Content-Length':'10'}}));
 assert.equal(response.headers.get('content-length'),'10');
 await assert.rejects(response.arrayBuffer(),/Truncated/);
});
test('release body transfer is not aborted by the former 30 second deadline',async()=>{
 const original=AbortSignal.timeout;const delays=[];
 AbortSignal.timeout=ms=>{delays.push(ms);return original(ms)};
 try{const result=await request('onenew-node-linux-amd64.tar.gz',new Response(new Uint8Array([31,139,8,0])));await result.arrayBuffer();assert.ok(delays[0]>=900000)}finally{AbortSignal.timeout=original}
});
test('public source and its checksum have fixed names',async()=>{
 assert.equal((await request('onenew-node-source.tar.gz',new Response(new Uint8Array([31,139,8,0])))).status,200);
 assert.equal((await request('SHA256SUMS-source',new Response('b'.repeat(64)+'  onenew-node-source.tar.gz\n'))).status,200);
});
