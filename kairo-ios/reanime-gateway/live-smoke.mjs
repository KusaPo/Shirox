import crypto from 'node:crypto';
import { resolveEmbed } from './resolve.mjs';
import { decodePlaylist, unwrapSegment } from './server.mjs';

const metadata = await fetch('https://reanime.to/api/flix/178789/1', { headers: {
  Accept: 'application/json', 'User-Agent': 'Mozilla/5.0', Referer: 'https://reanime.to/'
}});
const chosenServer = process.env.REANIME_SMOKE_SERVER || 'HD-1';
const chosenAudio = process.env.REANIME_SMOKE_AUDIO || 'dub';
let embed = 'https://flixcloud.cc/e/iok35hilu01s?v=1';
if (metadata.ok) {
  const servers = (await metadata.json()).servers ?? [];
  embed = servers.find(item => item.serverName === chosenServer && item.dataType === chosenAudio)?.dataLink ?? embed;
} else console.log(`ReAnime catalog probe returned HTTP ${metadata.status}; trying the previously observed embed`);
const resolved = await resolveEmbed(embed);
const headers = { 'User-Agent': 'Mozilla/5.0', Referer: 'https://flixcloud.cc/', Origin: 'https://flixcloud.cc' };
let url = new URL(resolved.stream);
for (let level = 0; level < 3; level++) {
  const response = await fetch(url, { headers });
  if (!response.ok) throw new Error(`Playlist HTTP ${response.status}`);
  const playlist = decodePlaylist(Buffer.from(await response.arrayBuffer()), resolved.playlistKey);
  const next = playlist.split(/\r?\n/).find(line => line && !line.startsWith('#'));
  if (!next) throw new Error('Playlist has no media URI');
  url = new URL(next, response.url);
  if (!url.hostname.endsWith('.flixcloud.cc') && !url.hostname.endsWith('.rundowncdn.top') && !url.hostname.endsWith('.kineticcdn.top') && !url.hostname.endsWith('.ignitecdn.top')) throw new Error('Unrecognized ReAnime CDN host: ' + url.hostname);
  if (!url.pathname.endsWith('.m3u8')) {
    const segment = await fetch(url, { headers });
    if (!segment.ok) throw new Error(`Segment HTTP ${segment.status}`);
    let bytes = unwrapSegment(Buffer.from(await segment.arrayBuffer()));
    const keyLine = playlist.split(/\r?\n/).find(line => line.startsWith('#EXT-X-KEY:'));
    if (keyLine?.includes('METHOD=AES-128')) {
      const keyPath = /URI="([^"]+)"/.exec(keyLine)?.[1], ivHex = /IV=0x([a-f0-9]+)/i.exec(keyLine)?.[1];
      if (!keyPath || !ivHex) throw new Error('Smoke test needs an explicit HLS key and IV');
      const keyResponse = await fetch(new URL(keyPath, response.url), {headers});
      if (!keyResponse.ok) throw new Error('HLS key request failed');
      const key = Buffer.from(await keyResponse.arrayBuffer());
      const cipher = crypto.createDecipheriv('aes-128-cbc', key, Buffer.from(ivHex, 'hex'));
      bytes = Buffer.concat([cipher.update(bytes), cipher.final()]);
    }
    if (!bytes.length || ![0x47, 0x00].includes(bytes[0])) throw new Error('Segment format is not verified');
    console.log(`Verified ReAnime ${chosenServer} ${chosenAudio} playlist and ${bytes.length}-byte first segment`);
    process.exit(0);
  }
}
throw new Error('Playlist nesting exceeded smoke test limit');
