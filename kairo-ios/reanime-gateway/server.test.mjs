import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pageData, playlistKey } from './resolve.mjs';
process.env.GATEWAY_SECRET = 'the-unit-test-secret-is-long-enough-to-use';
const { ticket, unticket, decodePlaylist, unwrapSegment } = await import('./server.mjs');

test('SSR data parser handles quoted braces without executing code', () => {
  const data = pageData('<script>{type:"data",data:{obfuscation_seed:"ab12", title:"A {day}", nested:{number:2}, empty:undefined, enabled:!0}}</script>');
  assert.equal(data.title, 'A {day}');
  assert.equal(data.nested.number, 2);
  assert.equal(data.empty, null);
  assert.equal(data.enabled, true);
});
test('playlist key comes from paired bytes in WASM data', () => {
  const left = Buffer.alloc(32, 17), right = Buffer.alloc(32, 42);
  const segment = Buffer.concat([left, right]);
  const wasm = Buffer.concat([Buffer.from([0,97,115,109,1,0,0,0, 11,70, 1,0,65,0,11,64]), segment]);
  assert.deepEqual(Buffer.from(playlistKey(wasm.toString('base64')), 'base64'), Buffer.alloc(32, 17 ^ 42));
});
test('plain and encoded playlists produce HLS', () => {
  const playlist = '#EXTM3U\n#EXT-X-VERSION:3\n';
  assert.equal(decodePlaylist(Buffer.from(playlist)), playlist.trim());
  const key = Buffer.from([15, 34, 47]);
  const encoded = Buffer.from(playlist);
  for (let i = 0; i < encoded.length; i++) encoded[i] ^= key[i % key.length];
  assert.equal(decodePlaylist(Buffer.from(encoded.toString('base64')), key.toString('base64')), playlist.trim());
  assert.throws(() => decodePlaylist(Buffer.from('not a playlist'), null));
});
test('wrapped transport segment becomes transport bytes', () => {
  const raw = Buffer.from([0x47, 0x40, 0x00, 0x10]);
  const header = Buffer.from([137,80,78,71,13,10,26,10]);
  assert.deepEqual(unwrapSegment(Buffer.concat([header, raw])), raw);
});
test('tickets reject host substitution and expiry', () => {
  const good = ticket({ url: 'https://fetch1.flixcloud.cc/episode.ts', expires: Date.now() + 10_000 });
  assert.match(unticket(good).url, /fetch1/);
  assert.throws(() => unticket(good.slice(0, -2) + 'xx'));
  assert.throws(() => unticket(ticket({ url: 'https://example.com/episode.ts', expires: Date.now() + 10_000 })));
  assert.throws(() => unticket(ticket({ url: 'https://fetch1.flixcloud.cc/episode.ts', expires: Date.now() - 1 })));
});
