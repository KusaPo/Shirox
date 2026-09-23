'use strict';
// Synthetic fixtures only: these tests do NOT establish live-site or iOS playback.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const core = fs.readFileSync(path.join(__dirname, 'reanime-core.js'), 'utf8');
const BASE = 'https://reanime.to';
const SLUG = 'test-series-q7k42p';
const AL = 10101;
const EMBED = 'https://flixcloud.cc/e/test-episode';
const MEDIA = 'https://cdn.example.test/video/master.m3u8?token=a%2Bb&expires=9000';
const VTT = 'https://subs.example.test/English.vtt?signature=c%2Bd';
const MASTER = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720\n720/index.m3u8\n';
const item = { anime_id: SLUG, title: { english: 'Test &amp; Series', romaji: 'Tesuto', native: 'テスト' },
    cover_image: { large: `https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx${AL}-test.jpg` },
    anilist_id: AL, subbed: 3, dubbed: 2, episodes: 3,
    description: '<p>A &amp; B.<br>Second line.</p>', start_date: { year: 2026, month: 9, day: 1 } };
const subserver = { '$id': 'first', serverName: 'HD-2', dataType: 'sub', dataLink: EMBED };
const dubserver = { '$id': 'second', serverName: 'HD-2', dataType: 'dub', dataLink: EMBED + '-dub' };
function reply(body, status = 200, headers = {}) {
    return { status, ok: status >= 200 && status < 300, headers,
        // These functions are synchronous, as they are in ShiroX's JS bridge.
        text() { return typeof body === 'string' ? body : JSON.stringify(body); } };
}
function fixture(url) {
    if (url.startsWith(BASE + '/api/v1/search?')) return reply({ results: [item] });
    if (url === `${BASE}/api/v1/anime/${SLUG}`) return reply(item);
    if (url === `${BASE}/api/v1/anime/${SLUG}/episodes?limit=2000`) return reply({ data: [
        { episode_number: 3 }, { episode_number: 1 }, { episode_number: '2' }, { episode_number: 2 },
        { episode_number: null }, { episode_number: 'bad' }
    ] });
    if (url === `${BASE}/api/watch/${SLUG}/1`) return reply({ episode_links: [subserver, dubserver] });
    if (url === `${BASE}/api/flix/${AL}/1`) return reply({ success: true, servers: [] });
    if (url === MEDIA) return reply(MASTER, 200, { 'Content-Type': 'application/vnd.apple.mpegurl' });
    throw new Error('Unexpected fixture request: ' + url);
}
function defaultCapture() {
    return { success: true, requests: [
        EMBED, 'https://flixcloud.cc/api/m3u8/token',
        'https://ads.example.test/ads/preroll.mp4', MEDIA, MEDIA,
        'https://cdn.example.test/thumbs/storyboard.vtt'
    ], html: `<script>const data={subtitles:[{file:'${VTT}',label:'English',kind:'captions'},{file:'https://subs.example.test/es.vtt',label:'Spanish'}]};</script>` };
}
function runtime({ audio = 'sub', fetcher = fixture, capture = defaultCapture, noNetwork = false, noBridge = false, noTimers = false } = {}) {
    const calls = [], browserCalls = [], logs = [];
    const context = { console: { log: text => logs.push(text), warn: text => logs.push(text), error: text => logs.push(text) } };
    if (!noTimers) Object.assign(context, { setTimeout, clearTimeout });
    if (!noBridge) context.fetchv2 = async (url, headers, method, body) => {
        calls.push({ url, headers, method, body });
        return fetcher(url, headers, method, body);
    };
    if (!noNetwork) context.networkFetch = async (url, options) => {
        browserCalls.push({ url, options });
        return capture(url, options);
    };
    vm.createContext(context);
    vm.runInContext(`var REANIME_AUDIO = ${JSON.stringify(audio)};\n` + core, context, { timeout: 2000 });
    return { context, calls, browserCalls, logs, h: context.ReAnime._test };
}
const episodeKey = `${BASE}/watch/${SLUG}?lang=sub&ep=1&al=${AL}`;
const json = x => JSON.parse(JSON.stringify(x));

test('exports the four ShiroX module entry points without browser or Node globals', () => {
    const { context } = runtime();
    for (const name of ['searchResults', 'extractDetails', 'extractEpisodes', 'extractStreamUrl']) assert.equal(typeof context[name], 'function');
    assert.equal(vm.runInContext('typeof URL', context), 'undefined');
    assert.equal(vm.runInContext('typeof document', context), 'undefined');
    assert.equal(vm.runInContext('typeof crypto', context), 'undefined');
});
test('empty search performs no HTTP request', async () => {
    const r = runtime(); assert.equal(await r.context.searchResults('  '), '[]'); assert.equal(r.calls.length, 0);
});
test('search encodes user text and returns correct ShiroX fields', async () => {
    const r = runtime(); const results = JSON.parse(await r.context.searchResults('A & B?'));
    assert.equal(results.length, 1); assert.equal(results[0].title, 'Test & Series');
    assert.match(results[0].href, /lang=sub&al=10101$/);
    assert.equal(r.calls[0].url, BASE + '/api/v1/search?q=A%20%26%20B%3F&limit=10');
    assert.equal(r.calls[0].method, 'GET');
});
test('search filters unavailable language and deduplicates source identifiers', async () => {
    const r = runtime({ audio: 'dub', fetcher: () => reply({ results: [item, item, { ...item, anime_id: 'no-dub', dubbed: 0 }] }) });
    const rows = JSON.parse(await r.context.searchResults('test'));
    assert.equal(rows.length, 1); assert.match(rows[0].href, /lang=dub/);
});
test('unknown audio count is not incorrectly treated as zero', async () => {
    const r = runtime({ audio: 'dub', fetcher: () => reply({ results: [{ ...item, dubbed: null }] }) });
    assert.equal(JSON.parse(await r.context.searchResults('test')).length, 1);
});
test('search schema changes fail explicitly instead of silently returning no titles', async () => {
    const r = runtime({ fetcher: () => reply({ unexpected: [] }) });
    await assert.rejects(r.context.searchResults('test'), /Search response has changed/);
});
test('HTTP 403 surfaces source verification guidance', async () => {
    const r = runtime({ fetcher: () => reply('<html>challenge</html>', 403) });
    await assert.rejects(r.context.searchResults('test'), /HTTP 403.*verification/);
});
test('HTTP 429 surfaces rate-limit guidance', async () => {
    const r = runtime({ fetcher: () => reply('rate limited', 429) });
    await assert.rejects(r.context.searchResults('test'), /HTTP 429/);
});
test('HTML in a successful API response is not misparsed as an empty result', async () => {
    const r = runtime({ fetcher: () => reply('<html>verification</html>') });
    await assert.rejects(r.context.searchResults('test'), /Expected JSON/);
});
test('details strip HTML, preserve line breaks, expose aliases and partial-safe dates', async () => {
    const r = runtime(); const [d] = JSON.parse(await r.context.extractDetails(`/anime/${SLUG}`));
    assert.equal(d.description, 'A & B.\nSecond line.'); assert.equal(d.airdate, '2026-09-01');
    assert.match(d.aliases, /Tesuto/); assert.match(d.aliases, /テスト/);
});
test('detail cache avoids refetching fresh metadata', async () => {
    const r = runtime(); await r.context.extractDetails(SLUG); await r.context.extractDetails(SLUG);
    assert.equal(r.calls.length, 1);
});
test('episode list preserves numeric numbers, sorts and deduplicates', async () => {
    const r = runtime(); const eps = JSON.parse(await r.context.extractEpisodes(SLUG));
    assert.deepEqual(eps.map(e => e.number), [1, 2, 3]);
    assert.match(eps[0].href, /lang=sub&ep=1&al=10101$/);
});
test('dub module caps episodes using the reported dub count', async () => {
    const r = runtime({ audio: 'dub' }); const eps = JSON.parse(await r.context.extractEpisodes(SLUG));
    assert.deepEqual(eps.map(e => e.number), [1, 2]); assert.match(eps[0].href, /lang=dub/);
});
test('episode catalog remains usable when optional details are unavailable', async () => {
    const r = runtime({ fetcher: url => url === `${BASE}/api/v1/anime/${SLUG}` ? reply('unavailable', 503) : fixture(url) });
    const eps = JSON.parse(await r.context.extractEpisodes(SLUG)); assert.equal(eps.length, 3);
});
test('unexpected additional episode pages fail explicitly', async () => {
    const r = runtime({ fetcher: url => url.includes('/episodes?') ? reply({ data: [], pagination: { hasNextPage: true } }) : fixture(url) });
    await assert.rejects(r.context.extractEpisodes(SLUG), /paginated/);
});
test('key parsing supports sub/dub and fractional episode numbers', () => {
    const { h } = runtime();
    assert.deepEqual(json(h.keyInfo(`/watch/${SLUG}?ep=12.5&lang=dub&al=88`)), { slug: SLUG, episode: 12.5, audio: 'dub', anilist: 88 });
});
test('source keys reject cross-site URLs and invalid identifiers', () => {
    const { h } = runtime();
    assert.throws(() => h.keyInfo(`https://unrelated.example.test/anime/${SLUG}`), /different website/);
    assert.throws(() => h.keyInfo('not a slug / <tag>'), /Invalid anime link/);
});
test('media URLs reject private destinations and executable schemes', () => {
    const { h } = runtime();
    for (const s of ['javascript:alert(1)', 'file:///tmp/x', 'https://127.0.0.1/x', 'https://192.168.1.2/a', 'http://169.254.169.254/x', 'https://localhost/a', 'https://user:pass@example.test/x']) assert.equal(h.publicURL(s), '');
    assert.equal(h.publicURL(MEDIA), MEDIA);
});
test('restricted parser reads safe object-literal subtitles, escapes and trailing commas', () => {
    const { h } = runtime();
    const parsed = h.readLiteral(`[{label:'English',file:"https:\\/\\/test.example.test\\/s.vtt?a=1\\u0026b=2",default:!0, x:undefined,},]`);
    assert.deepEqual(json(parsed.value), [{ label: 'English', file: 'https://test.example.test/s.vtt?a=1&b=2', default: true, x: null }]);
});
test('restricted parser never executes expressions or changes object prototypes', () => {
    const r = runtime();
    assert.throws(() => r.h.readLiteral('[{x:(function(){ throw 1 })()}]'), /Unsupported/);
    assert.deepEqual(json(r.h.readLiteral('{__proto__:{polluted:true},safe:1}').value), { safe: 1 });
    assert.equal(vm.runInContext('({}).polluted', r.context), undefined);
});
test('subtitle extraction reads metadata and HTML track tags without adding thumbnails', () => {
    const { h } = runtime();
    const capture = defaultCapture();
    const tracks = json(h.subtitleTracks(capture.html + '<track kind="metadata" src="/thumbs.vtt"><track kind="subtitles" label="French" src="/fr.vtt">', capture.requests, EMBED, { Referer: 'https://flixcloud.cc/' }));
    assert.equal(tracks.length, 3); assert.equal(tracks[0].title, 'English'); assert.equal(tracks[0].url, VTT);
    assert.ok(tracks.some(t => t.title === 'French' && t.url === 'https://flixcloud.cc/fr.vtt'));
});
test('candidate filtering keeps signed URLs intact and excludes ads, token APIs and blob URLs', () => {
    const { h } = runtime(); const capture = defaultCapture();
    capture.requests.push('blob:https://flixcloud.cc/example', 'https://example.test/redirect?next=video.m3u8');
    const urls = json(h.candidates(capture, EMBED)); assert.deepEqual(urls, [MEDIA]);
});
test('complete mocked search-to-playback flow yields ShiroX stream and subtitle schema', async () => {
    const r = runtime();
    const [found] = JSON.parse(await r.context.searchResults('test'));
    const [ep] = JSON.parse(await r.context.extractEpisodes(found.href));
    const play = JSON.parse(await r.context.extractStreamUrl(ep.href));
    assert.equal(play.streams.length, 1); assert.equal(play.streams[0].streamUrl, MEDIA);
    assert.equal(play.streams[0].headers.Referer, 'https://flixcloud.cc/');
    assert.equal(play.subtitle, VTT); assert.equal(play.allSubtitles.length, 2);
    assert.equal(r.browserCalls[0].url, EMBED + '?autoPlay=true');
    assert.equal(r.browserCalls[0].options.returnCookies, false);
    assert.equal('Cookie' in play.streams[0].headers, false);
});
test('dub playback uses the dub server instead of silently falling back to sub', async () => {
    const r = runtime({ audio: 'dub' });
    const result = JSON.parse(await r.context.extractStreamUrl(episodeKey.replace('lang=sub', 'lang=dub')));
    assert.match(result.streams[0].title, /^DUB/); assert.equal(r.browserCalls[0].url, EMBED + '-dub?autoPlay=true');
});
test('secondary server endpoint can recover when primary endpoint fails', async () => {
    const r = runtime({ fetcher: url => {
        if (url.includes('/api/watch/')) return reply('unavailable', 503);
        if (url.includes('/api/flix/')) return reply({ success: true, servers: [subserver] });
        return fixture(url);
    } });
    assert.equal(JSON.parse(await r.context.extractStreamUrl(episodeKey)).streams[0].streamUrl, MEDIA);
});
test('resolver falls back to another eligible server after empty capture', async () => {
    const r = runtime({ fetcher: url => url.includes('/api/watch/') ? reply({ episode_links: [subserver,
        { ...subserver, serverName: 'HD-1', dataLink: EMBED + '-fallback' }] }) : fixture(url),
        capture: url => url.split('?')[0] === EMBED ? { success: true, requests: [], html: '' } : defaultCapture() });
    assert.equal(JSON.parse(await r.context.extractStreamUrl(episodeKey)).streams[0].streamUrl, MEDIA);
    assert.equal(r.browserCalls.length, 2);
});
test('soft-sub audio labels remain eligible', async () => {
    const r = runtime({ fetcher: url => url.includes('/api/watch/') ? reply({ episode_links: [{ ...subserver, dataType: 's-sub' }] }) : fixture(url) });
    assert.equal(JSON.parse(await r.context.extractStreamUrl(episodeKey)).streams.length, 1);
});
test('missing audio servers fail rather than selecting another language', async () => {
    const r = runtime({ audio: 'dub', fetcher: url => url.includes('/api/watch/') ? reply({ episode_links: [subserver] }) : fixture(url) });
    await assert.rejects(r.context.extractStreamUrl(episodeKey.replace('lang=sub', 'lang=dub')), /No DUB servers/);
    assert.equal(r.browserCalls.length, 0);
});
test('invalid video response cannot be returned as a successful stream', async () => {
    const r = runtime({ fetcher: url => url === MEDIA ? reply('<html>challenge</html>') : fixture(url) });
    await assert.rejects(r.context.extractStreamUrl(episodeKey), /could not be verified/);
});
test('verified alternate referer is returned with the stream', async () => {
    const r = runtime({ fetcher: (url, headers) => url === MEDIA && headers.Referer !== BASE + '/' ? reply('denied', 403) : fixture(url) });
    const play = JSON.parse(await r.context.extractStreamUrl(episodeKey));
    assert.equal(play.streams[0].headers.Referer, BASE + '/');
});
test('direct MP4 validation uses HEAD, never downloads the whole video as text', async () => {
    const media = 'https://cdn.example.test/full-episode.mp4';
    const r = runtime({ fetcher: (url, headers, method) => {
        assert.equal(url, media); assert.equal(method, 'HEAD'); return reply('', 200, { 'content-type': 'video/mp4' });
    } });
    const result = await r.h.captureServer({ serverName: 'Direct', dataLink: media }, Date.now() + 30000);
    assert.equal(result.streams[0].streamUrl, media); assert.equal(r.browserCalls.length, 0);
});
test('subtitle-only HLS manifests are not accepted as video', async () => {
    const r = runtime({ fetcher: () => reply('#EXTM3U\n#EXTINF:10,\nEnglish.vtt\n#EXT-X-ENDLIST\n') });
    assert.equal(await r.h.verifyMedia(MEDIA, EMBED, Date.now() + 20000), null);
});
test('missing runtime player capture gives an actionable error', async () => {
    const r = runtime({ noNetwork: true });
    await assert.rejects(r.context.extractStreamUrl(episodeKey), /networkFetch/);
});
test('missing HTTP bridge gives an actionable error', async () => {
    const r = runtime({ noBridge: true });
    await assert.rejects(r.context.searchResults('test'), /HTTP bridge/);
});
test('stream lookup rejects a series link with no episode number', async () => {
    const r = runtime(); await assert.rejects(r.context.extractStreamUrl(SLUG), /Open an episode/);
});
test('pure parser works with no setTimeout or browser APIs', async () => {
    const r = runtime({ noTimers: true });
    assert.equal(JSON.parse(await r.context.searchResults('test')).length, 1);
});
test('module logs never contain signed media or subtitle URLs', async () => {
    const r = runtime(); await r.context.extractStreamUrl(episodeKey);
    const logs = r.logs.join('\n'); assert.ok(!logs.includes(MEDIA)); assert.ok(!logs.includes(VTT)); assert.ok(!logs.includes('token='));
});
test('saved episode audio is preserved and labeled correctly after switching modules', async () => {
    const r = runtime({ audio: 'dub' });
    const result = JSON.parse(await r.context.extractStreamUrl(episodeKey));
    assert.match(result.streams[0].title, /^SUB/);
    assert.equal(r.browserCalls[0].url, EMBED + '?autoPlay=true');
});


test('player failures emit visible error diagnostics without signed URLs', async () => {
    const r = runtime({ capture: () => { throw new Error('Request failed at ' + MEDIA); } });
    let visible = '';
    r.context.console.error = message => { visible = message; };
    await assert.rejects(r.context.extractStreamUrl(episodeKey), /URL omitted/);
    assert.match(visible, /ReAnime 0.1.1/);
    assert.ok(!visible.includes('token='));
    assert.ok(!r.logs.join('\n').includes(MEDIA));
});

test('host player options preserve its parameters and await the rendered video', async () => {
    const r = runtime();
    await r.h.captureServer({ dataLink: EMBED + '?v=2#player', serverName: 'HD-2' }, Date.now() + 30000);
    assert.equal(r.browserCalls[0].url, EMBED + '?v=2&autoPlay=true#player');
    assert.deepEqual(json(r.browserCalls[0].options.waitForSelectors), ['video']);
    assert.ok(r.browserCalls[0].options.clickSelectors.includes('.art-icon-play[aria-label="Play"]'));
    assert.ok(!r.browserCalls[0].options.clickSelectors.includes('video'));
});
