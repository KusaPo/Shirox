import http from 'node:http';
import crypto from 'node:crypto';
import { resolveEmbed } from './resolve.mjs';

const secret = process.env.GATEWAY_SECRET;
if (!secret || secret.length < 32) throw new Error('Set GATEWAY_SECRET to at least 32 random characters');
const port = Number(process.env.PORT || 8080);
const signature = data => crypto.createHmac('sha256', secret).update(data).digest('base64url');
const permitted = url => url.protocol === 'https:' && url.hostname.endsWith('.flixcloud.cc') && url.hostname !== '.flixcloud.cc';

export function ticket(payload) {
  const data = Buffer.from(JSON.stringify(payload)).toString('base64url');
  return `${data}.${signature(data)}`;
}
export function unticket(value) {
  const [data, mac] = value.split('.');
  if (!data || !mac || !crypto.timingSafeEqual(Buffer.from(signature(data)), Buffer.from(mac))) throw new Error('Invalid media ticket');
  const payload = JSON.parse(Buffer.from(data, 'base64url').toString('utf8'));
  if (!Number.isFinite(payload.expires) || payload.expires < Date.now() || !permitted(new URL(payload.url))) throw new Error('Expired or invalid media ticket');
  return payload;
}
export function decodePlaylist(body, key) {
  const plain = body.toString('utf8').trim();
  if (plain.startsWith('#EXTM3U')) return plain;
  if (!key || !/^[A-Za-z0-9+/=]+$/.test(key)) throw new Error('Encoded playlist needs a key');
  const bytes = Buffer.from(plain, 'base64'), mask = Buffer.from(key, 'base64');
  if (!mask.length || bytes.length > 2_000_000) throw new Error('Invalid encoded playlist');
  for (let i = 0; i < bytes.length; i++) bytes[i] ^= mask[i % mask.length];
  const decoded = bytes.toString('utf8').trim();
  if (!decoded.startsWith('#EXTM3U')) throw new Error('Playlist decoding failed');
  return decoded;
}
const imageMask = Buffer.from([157,42,241,71,179,142,92,112,166,25,228,59,216,98,15,197]);
export function unwrapSegment(body) {
  const webp = body.toString('ascii', 0, 4) === 'RIFF' && body.toString('ascii', 8, 12) === 'WEBP';
  const png = body.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]));
  const offset = webp ? 12 : png ? 8 : 0;
  if (!offset) return body;
  const bytes = Buffer.from(body.subarray(offset));
  if (bytes[0] !== 0x47) for (let i = 0; i < bytes.length; i++) bytes[i] ^= imageMask[i % imageMask.length];
  return bytes;
}

async function fetchMedia(value, range) {
  let url = new URL(value);
  for (let n = 0; n < 4; n++) {
    if (!permitted(url)) throw new Error('Media host is not allowed');
    const response = await fetch(url, { redirect: 'manual', headers: {
      'User-Agent': 'Mozilla/5.0', Referer: 'https://flixcloud.cc/', Origin: 'https://flixcloud.cc',
      ...(range ? { Range: range } : {})
    }});
    if ([301,302,303,307,308].includes(response.status)) { url = new URL(response.headers.get('location'), url); continue; }
    if (!response.ok) throw new Error(`Media returned HTTP ${response.status}`);
    return { response, url };
  }
  throw new Error('Too many media redirects');
}
function rewrite(text, base, key, expires, origin) {
  const link = raw => {
    const url = new URL(raw, base);
    if (!permitted(url)) throw new Error('Playlist contains another media host');
    const payload = ticket({ url: url.href, key, expires });
    const suffix = url.pathname.toLowerCase();
    const route = suffix.endsWith('.m3u8') ? 'master.m3u8' : suffix.endsWith('.key') ? 'key.bin' : 'segment.ts';
    return `${origin}/hls/${route}?t=${payload}`;
  };
  return text.split(/\r?\n/).map(line => {
    if (line.startsWith('#')) return line.replace(/URI="([^"]+)"/g, (_, value) => `URI="${link(value)}"`);
    return line.trim() ? link(line.trim()) : line;
  }).join('\n');
}
const reply = (res, status, data, type = 'application/json') => {
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' }); res.end(data);
};

export function createGateway(resolve = resolveEmbed) {
  return http.createServer(async (req, res) => {
    try {
      if (req.method !== 'GET') { reply(res, 405, '{}'); return; }
      const request = new URL(req.url, 'http://localhost');
      if (request.pathname === '/health') { reply(res, 200, JSON.stringify({ ready: true })); return; }
      if (request.pathname === '/resolve') {
        const access = process.env.GATEWAY_ACCESS_KEY;
        const provided = req.headers['x-kairo-access'] || '';
        if (!access || access.length < 24 || provided.length !== access.length ||
            !crypto.timingSafeEqual(Buffer.from(provided), Buffer.from(access))) {
          reply(res, 401, JSON.stringify({ error: 'Gateway access key required' })); return;
        }
        const media = await resolve(request.searchParams.get('embed') ?? '');
        const source = new URL(media.stream);
        if (!permitted(source)) throw new Error('Invalid resolved media URL');
        const expires = Date.now() + 4 * 60 * 60 * 1000;
        const { response, url } = await fetchMedia(source.href);
        const playlist = decodePlaylist(Buffer.from(await response.arrayBuffer()), media.playlistKey);
        // Fail before offering playback if the first playlist is not standard HLS.
        if (!playlist.startsWith('#EXTM3U')) throw new Error('No playable HLS playlist');
        const token = ticket({ url: url.href, key: media.playlistKey, expires });
        const origin = process.env.PUBLIC_ORIGIN;
        if (!origin || !/^https:\/\//.test(origin)) throw new Error('Set PUBLIC_ORIGIN to the gateway HTTPS address');
        reply(res, 200, JSON.stringify({ url: `${origin.replace(/\/$/, '')}/hls/master.m3u8?t=${token}` }));
        return;
      }
      if (request.pathname.startsWith('/hls/')) {
        const media = unticket(request.searchParams.get('t') ?? '');
        // Return a complete resource: transformed image-wrapped segments do not
        // have the same byte offsets as their upstream representation.
        const { response, url } = await fetchMedia(media.url);
        const bytes = Buffer.from(await response.arrayBuffer());
        if (request.pathname.endsWith('.m3u8')) {
          const playlist = decodePlaylist(bytes, media.key);
          const origin = process.env.PUBLIC_ORIGIN.replace(/\/$/, '');
          reply(res, 200, rewrite(playlist, url, media.key, media.expires, origin), 'application/vnd.apple.mpegurl');
        } else {
          const video = unwrapSegment(bytes);
          res.writeHead(200, { 'Content-Type': request.pathname.endsWith('key.bin') ? 'application/octet-stream' : video === bytes ? (response.headers.get('content-type') || 'video/mp2t') : 'video/mp2t', 'Content-Length': video.length });
          res.end(video);
        }
        return;
      }
      reply(res, 404, '{}');
    } catch (error) { reply(res, 502, JSON.stringify({ error: error.message })); }
  });
}
if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  createGateway().listen(port, '0.0.0.0', () => console.log(`Kairo media gateway on ${port}`));
}
