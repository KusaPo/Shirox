'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
for (const audio of ['sub', 'dub']) {
    test(audio + ' embedded manifest contains identical cached and data-URI scripts', () => {
        const root = path.join(__dirname, 'modules', 'reanime-' + audio);
        const manifest = JSON.parse(fs.readFileSync(root + '.json', 'utf8'));
        const script = fs.readFileSync(root + '.js', 'utf8');
        assert.equal(manifest.type, 'anime'); assert.equal(manifest.asyncJS, true);
        assert.equal(manifest.scriptContent, script);
        assert.equal(Buffer.from(manifest.scriptUrl.split(',')[1], 'base64').toString('utf8'), script);
        assert.equal(manifest.version, '0.1.0');
        assert.equal(manifest.baseUrl, 'https://reanime.to');
        assert.ok(!manifest.scriptUrl.includes('YOUR_'));
        assert.doesNotThrow(() => new URL(manifest.scriptUrl));
    });
    test(audio + ' packaged script executes and exposes every required function', () => {
        const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'modules', 'reanime-' + audio + '.json'), 'utf8'));
        const context = vm.createContext({});
        vm.runInContext(manifest.scriptContent, context, { timeout: 1000 });
        for (const name of ['searchResults', 'extractDetails', 'extractEpisodes', 'extractStreamUrl']) assert.equal(typeof context[name], 'function');
        assert.equal(context.REANIME_AUDIO, audio);
    });
}
