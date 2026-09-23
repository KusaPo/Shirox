'use strict';
/*
 * node build.cjs                    -> one-file, ShiroX-specific beta manifests
 * node build.cjs https://host/path  -> conventional JSON + hosted JS manifests
 * No upload/publishing is performed by this script.
 */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const base = process.argv[2];
if (base) {
    let parsed;
    try { parsed = new URL(base); } catch { console.error('Supply an absolute HTTPS folder URL.'); process.exit(1); }
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.search || parsed.hash) {
        console.error('Use an HTTPS folder URL without credentials, query parameters, or a fragment.'); process.exit(1);
    }
}
const core = fs.readFileSync(path.join(__dirname, 'reanime-core.js'), 'utf8');
const folder = path.join(__dirname, base ? 'hosted' : 'modules');
fs.mkdirSync(folder, { recursive: true });
for (const audio of ['sub', 'dub']) {
    const name = 'reanime-' + audio;
    const script = `var REANIME_AUDIO = ${JSON.stringify(audio)};\n` + core;
    const module = {
        sourceName: 'ReAnime ' + audio.toUpperCase() + ' (Beta)',
        author: { name: 'Community module — unofficial' },
        version: '0.1.0',
        baseUrl: 'https://reanime.to',
        searchBaseUrl: 'https://reanime.to/api/v1/search?q=',
        scriptUrl: base ? base.replace(/\/$/, '') + '/' + name + '.js' :
            'data:application/javascript;base64,' + Buffer.from(script, 'utf8').toString('base64'),
        type: 'anime',
        asyncJS: true,
        streamType: 'HLS/MP4',
        language: audio === 'dub' ? 'English dub' : 'Japanese / subtitles',
        softsub: true
    };
    if (!base) {
        // ShiroX decodes scriptContent and executes it before fetching scriptUrl.
        // Its asset-cache attempt only overwrites this value on a successful
        // fetch. The data URI contains identical JS for runtimes that fetch it.
        // This single-file import path is source-checked, not device-tested.
        module.scriptContent = script;
    }
    fs.writeFileSync(path.join(folder, name + '.js'), script);
    fs.writeFileSync(path.join(folder, name + '.json'), JSON.stringify(module, null, 2) + '\n');
    console.log('Created ' + path.relative(__dirname, path.join(folder, name + '.json')));
    if (base) console.log('Import URL after upload: ' + base.replace(/\/$/, '') + '/' + name + '.json');
    console.log('JS SHA-256: ' + crypto.createHash('sha256').update(script).digest('hex'));
}
