import crypto from 'node:crypto';
import JSON5 from 'json5';

const hash = input => crypto.createHash('sha256').update(input).digest('hex');
const binary = input => Buffer.from(input, 'base64');

// SvelteKit serializes this data as a JavaScript object literal rather than JSON.
// Scan braces while respecting quoted strings; JSON5 parses data, never executes it.
export function pageData(html) {
  const marker = /\{type:"data",data:\s*\{/g.exec(html);
  if (!marker) throw new Error('FlixCloud did not expose episode data');
  const start = marker.index + marker[0].lastIndexOf('{');
  let depth = 0, quote = '', escape = false;
  for (let i = start; i < html.length; i++) {
    const c = html[i];
    if (quote) {
      if (escape) escape = false;
      else if (c === '\\') escape = true;
      else if (c === quote) quote = '';
      continue;
    }
    if (c === '"' || c === "'") { quote = c; continue; }
    if (c === '{') depth++;
    if (c === '}' && --depth === 0) return JSON5.parse(normalizeValues(html.slice(start, i + 1)));
  }
  throw new Error('Incomplete FlixCloud episode data');
}

function normalizeValues(source) {
  // Svelte's object literal occasionally uses JS-only values. Replace them
  // outside strings, leaving quoted episode metadata untouched.
  let result = '', quote = '', escaping = false;
  for (let i = 0; i < source.length; i++) {
    const c = source[i];
    if (quote) {
      result += c;
      if (escaping) escaping = false;
      else if (c === '\\') escaping = true;
      else if (c === quote) quote = '';
      continue;
    }
    if (c === '"' || c === "'") { quote = c; result += c; continue; }
    const previous = source[i - 1] ?? '';
    const next = source[i + 9] ?? '';
    if (source.startsWith('undefined', i) && next !== ':' && !/[\w$]/.test(previous) && !/[\w$]/.test(next)) {
      result += 'null'; i += 8; continue;
    }
    if (c === '!' && (source[i + 1] === '0' || source[i + 1] === '1')) {
      result += source[i + 1] === '0' ? 'true' : 'false'; i++; continue;
    }
    result += c;
  }
  return result;
}

// The playlist XOR key is stored as two halves of a WASM data segment.
// Read the data section without running untrusted code to recover that key.
export function playlistKey(wasmBase64) {
  const wasm = binary(wasmBase64);
  if (wasm.subarray(0, 4).toString('hex') !== '0061736d') return null;
  const leb = (index) => {
    let result = 0, shift = 0, current;
    do {
      if (index >= wasm.length || shift > 28) throw new Error('Malformed WASM section');
      current = wasm[index++]; result |= (current & 127) << shift; shift += 7;
    } while (current & 128);
    return [result, index];
  };
  let position = 8;
  while (position < wasm.length) {
    const section = wasm[position++];
    const [size, next] = leb(position);
    position = next;
    const end = position + size;
    if (end > wasm.length) throw new Error('Malformed WASM section length');
    if (section === 11) {
      let index = position;
      const [count, afterCount] = leb(index); index = afterCount;
      for (let n = 0; n < count && index < end; n++) {
        const [flags, afterFlags] = leb(index); index = afterFlags;
        if (flags === 2) { [, index] = leb(index); }
        if (flags === 0 || flags === 2) {
          if (wasm[index++] !== 0x41) throw new Error('Unknown WASM offset expression');
          [, index] = leb(index);
          if (wasm[index++] !== 0x0b) throw new Error('Unknown WASM offset terminator');
        }
        const [length, afterLength] = leb(index); index = afterLength;
        const chunk = wasm.subarray(index, index + length); index += length;
        if (chunk.length >= 64) {
          const key = Buffer.alloc(32);
          for (let j = 0; j < 32; j++) key[j] = chunk[j] ^ chunk[j + 32];
          return key.toString('base64');
        }
      }
    }
    position = end;
  }
  return null;
}

function names(seed) {
  let first = seed;
  for (let i = 0; i < 3; i++) first = hash(first + i);
  let second = first;
  for (let i = 0; i < 3; i++) second = hash(second + i);
  return {
    container: 'cd_' + first.slice(24, 32), array: 'ad_' + first.slice(32, 40),
    object: 'od_' + first.slice(40, 48), fragment: 'kf_' + first.slice(8, 16),
    iv: 'ivf_' + first.slice(16, 24),
    token: first.slice(48, 64) + '_' + first.slice(56, 64),
    otherFragment: second.slice(0, 16) + '_' + second.slice(16, 24)
  };
}

async function transform(wasm, first, second, third, seed) {
  const { instance } = await WebAssembly.instantiate(binary(wasm));
  const { memory, _s, _r } = instance.exports;
  if (!memory || !_s || !_r || first.length !== second.length || first.length !== third.length || first.length > 256)
    throw new Error('FlixCloud changed its key transform');
  const bytes = new Uint8Array(memory.buffer);
  const length = first.length;
  bytes.set(first, 1024); bytes.set(second, 1024 + length); bytes.set(third, 1024 + length * 2);
  _s(Number.parseInt(seed.slice(0, 8), 16));
  _r(1024, 1024 + length, 1024 + length * 2, 1024 + length * 3, length);
  return Buffer.from(bytes.slice(1024 + length * 3, 1024 + length * 4));
}

export async function resolveEmbed(embed, get = fetch) {
  const url = new URL(embed);
  if (url.protocol !== 'https:' || url.hostname !== 'flixcloud.cc' || !/^\/e\/[a-zA-Z0-9_-]+$/.test(url.pathname) || !['1', '2'].includes(url.searchParams.get('v')))
    throw new Error('Expected a FlixCloud episode link');
  const headers = { 'User-Agent': 'Mozilla/5.0', Referer: 'https://reanime.to/' };
  const page = await get(url, { headers });
  if (!page.ok) throw new Error(`FlixCloud episode returned HTTP ${page.status}`);
  const data = pageData(await page.text());
  const seed = data.obfuscation_seed;
  if (typeof seed !== 'string' || !/^[a-f0-9]{8,}$/i.test(seed)) throw new Error('Missing FlixCloud seed');
  const fields = names(seed);
  const inner = data.obfuscated_crypto_data?.[fields.container]?.[fields.array]?.[0]?.[fields.object];
  const token = data[fields.token];
  if (!inner || typeof token !== 'string' || !/^[\w.-]+$/.test(token)) throw new Error('FlixCloud changed its token data');
  const tokenReply = await get(`https://flixcloud.cc/api/m3u8/${token}`, { headers });
  if (!tokenReply.ok) throw new Error(`FlixCloud token returned HTTP ${tokenReply.status}`);
  const payload = await tokenReply.json();
  const encrypted = binary(payload[hash(token + 'vid').slice(0, 10)]);
  const third = binary(payload[hash(token + 'key').slice(0, 10)]);
  const transformed = await transform(data.w_payload, binary(inner[fields.fragment]), binary(data[fields.otherFragment]), third, seed);
  const material = crypto.pbkdf2Sync(transformed, seed, 1000, 32, 'sha256');
  for (let i = 0; i < material.length; i++) material[i] ^= seed.charCodeAt(i % seed.length);
  const key = crypto.createHash('sha256').update(material).digest();
  const decrypt = crypto.createDecipheriv('aes-256-cbc', key, binary(inner[fields.iv]));
  const stream = Buffer.concat([decrypt.update(encrypted), decrypt.final()]).toString('utf8').trim();
  const streamURL = new URL(stream);
  if (streamURL.protocol !== 'https:' || !streamURL.hostname.endsWith('.flixcloud.cc')) throw new Error('Untrusted FlixCloud media host');
  return { stream, playlistKey: playlistKey(data.w_payload) };
}
