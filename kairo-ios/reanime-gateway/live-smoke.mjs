import { resolveEmbed } from './resolve.mjs';
import { decodePlaylist, unwrapSegment } from './server.mjs';

const metadata = await fetch('https://reanime.to/api/flix/178789/1', { headers: {
  Accept: 'application/json', 'User-Agent': 'Mozilla/5.0', Referer: 'https://reanime.to/'
}});
let embed = 'https://flixcloud.cc/e/iok35hilu01s?v=1';
if (metadata.ok) {
  const servers = (await metadata.json()).servers ?? [];
  embed = servers.find(item => item.serverName === 'HD-1' && item.dataType === 'dub')?.dataLink ?? embed;
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
  url = new URL(next, url);
  if (!url.hostname.endsWith('.flixcloud.cc')) throw new Error('Media URL left FlixCloud');
  if (!url.pathname.endsWith('.m3u8')) {
    const segment = await fetch(url, { headers });
    if (!segment.ok) throw new Error(`Segment HTTP ${segment.status}`);
    const bytes = unwrapSegment(Buffer.from(await segment.arrayBuffer()));
    if (!bytes.length || ![0x47, 0x00].includes(bytes[0])) throw new Error('Segment format is not verified');
    console.log(`Verified ReAnime HD-1 dub playlist and ${bytes.length}-byte first segment`);
    process.exit(0);
  }
}
throw new Error('Playlist nesting exceeded smoke test limit');
