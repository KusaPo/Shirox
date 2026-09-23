var REANIME_AUDIO = "dub";
/*
 * ReAnime for ShiroX — 0.1.1 beta, 2026-09-23.
 * Original integration; not affiliated with ShiroX, ReAnime, or video hosts.
 * Runtime: ShiroX fetchv2 + networkFetch (no Node, DOM, eval, or external JS).
 * The build prepends var REANIME_AUDIO = "sub" or "dub".
 * See README.md and SOURCES.md for compatibility and testing limitations.
 */
var ReAnime = (function () {
    "use strict";
    var BASE = "https://reanime.to";
    var AUDIO = typeof REANIME_AUDIO === "string" && REANIME_AUDIO === "dub" ? "dub" : "sub";
    var VERSION = "0.1.1";
    var detailCache = Object.create(null);
    var detailOrder = [];
    var CACHE_MS = 180000;
    var MAX_SERVERS = 3;
    var PLAYER_SECONDS = 16;
    var STREAM_BUDGET_MS = 100000;

    function error(message) { return new Error("ReAnime: " + message); }
    function log(message) {
        if (typeof console !== "undefined") {
            // ShiroX stores warn messages as General; log messages are Debug.
            var write = typeof console.warn === "function" ? console.warn : console.log;
            if (typeof write === "function") write("[ReAnime " + AUDIO.toUpperCase() + " " + VERSION + "] " + message);
        }
    }
    function safeFailure(err) {
        return String(err && err.message || err || "Unknown error")
            .replace(/https?:\/\/[^\s<>"']+/gi, "[URL omitted]").slice(0, 220);
    }
    function numeric(value) {
        if (value === null || value === undefined || value === "" || typeof value === "boolean") return null;
        var n = Number(value);
        return isFinite(n) && n >= 0 ? n : null;
    }
    function unescapeHTML(value) {
        return String(value || "").replace(/&(?:amp|quot|apos|lt|gt|nbsp|#39|#x27|#\d+|#x[0-9a-f]+);/gi, function (entity) {
            var map = { "&amp;": "&", "&quot;": '"', "&apos;": "'", "&#39;": "'", "&#x27;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " " };
            var lower = entity.toLowerCase();
            if (Object.prototype.hasOwnProperty.call(map, lower)) return map[lower];
            var code = lower.indexOf("&#x") === 0 ? parseInt(lower.slice(3, -1), 16) : parseInt(lower.slice(2, -1), 10);
            return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
        });
    }
    function plain(value) {
        return unescapeHTML(String(value || "").replace(/<br\s*\/?\s*>/gi, "\n")
            .replace(/<\/(?:p|div)>/gi, "\n").replace(/<[^>]*>/g, ""))
            .replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
    }
    // JSCore does not necessarily provide URL/URLSearchParams. Never decode an
    // entire signed media URL: that would corrupt escaped query parameters.
    function cleanURL(value) {
        return unescapeHTML(String(value || "").trim())
            .replace(/\\\//g, "/").replace(/\\u0026/gi, "&").replace(/\\u003d/gi, "=");
    }
    function absolute(value, base) {
        var s = cleanURL(value);
        if (/^https?:\/\//i.test(s)) return s;
        if (/^\/\//.test(s)) return "https:" + s;
        if (/^[a-z][a-z\d+.-]*:/i.test(s)) return "";
        if (!s) return "";
        var root = String(base || BASE).match(/^https?:\/\/[^/]+/i);
        if (!root) return "";
        if (s[0] === "/") return root[0] + s;
        return String(base || BASE + "/").replace(/[^/]*$/, "") + s;
    }
    function publicURL(value) {
        var s = cleanURL(value);
        var match = s.match(/^https?:\/\/([^/?#]+)(?:[/?#]|$)/i);
        if (!match || /[\s\\\x00-\x1f]/.test(s) || /[@\[\]]/.test(match[1])) return "";
        var host = match[1].split(":")[0].toLowerCase().replace(/\.$/, "");
        // Ignore local/private destinations accidentally returned by a provider.
        if (host === "localhost" || /\.(?:localhost|local)$/.test(host) || host.indexOf(".") === -1) return "";
        if (/^(?:0|10|127)\./.test(host) || /^169\.254\./.test(host) || /^192\.168\./.test(host) || /^172\.(?:1[6-9]|2\d|3[01])\./.test(host)) return "";
        return s;
    }
    function origin(value) {
        var match = String(value).match(/^https?:\/\/[^/]+/i);
        return match ? match[0] : BASE;
    }
    function remaining(deadline, maximum) {
        var ms = deadline ? Math.min(maximum, deadline - Date.now()) : maximum;
        if (ms < 250) throw error("Playback lookup timed out. Try the episode again.");
        return ms;
    }
    async function bounded(promise, ms) {
        if (typeof setTimeout !== "function") return await promise;
        var timer;
        try {
            return await Promise.race([promise, new Promise(function (_, reject) {
                timer = setTimeout(function () { reject(error("Network request timed out.")); }, ms);
            })]);
        } finally {
            if (typeof clearTimeout === "function" && timer !== undefined) clearTimeout(timer);
        }
    }
    async function request(url, headers, method, deadline, timeout) {
        var safe = publicURL(url);
        if (!safe) throw error("Invalid or non-public source URL.");
        var ms = remaining(deadline, timeout || 15000);
        var promise;
        if (typeof fetchv2 === "function") {
            promise = fetchv2(safe, headers || {}, method || "GET", null);
        } else if (typeof fetch === "function") {
            promise = fetch(safe, { headers: headers || {}, method: method || "GET" });
        } else {
            throw error("This ShiroX build has no supported HTTP bridge.");
        }
        return await bounded(promise, ms);
    }
    function statusOK(response) {
        if (!response) return false;
        if (typeof response.ok === "boolean") return response.ok;
        return Number(response.status) >= 200 && Number(response.status) < 300;
    }
    async function api(path, deadline) {
        var response = await request(BASE + path, { Accept: "application/json, */*", Referer: BASE + "/" }, "GET", deadline);
        if (/^\/api\/(?:watch|flix)\//.test(path)) log("Server API returned HTTP " + (Number(response && response.status) || 0) + ".");
        if (!statusOK(response)) {
            var status = Number(response && response.status) || 0;
            if (status === 403 || status === 429) throw error("Source returned HTTP " + status + ". Complete any verification offered by ShiroX, or retry later.");
            throw error("Source returned HTTP " + status + ".");
        }
        // Parse text ourselves: native json() can raise a JSContext exception
        // outside a normal rejected Promise on malformed/verification HTML.
        var text = await response.text();
        try { return JSON.parse(text); }
        catch (_) { throw error("Expected JSON but received a page or invalid data. Check source verification in ShiroX."); }
    }
    function keyInfo(key) {
        var s = String(key || "");
        if (/^https?:\/\//i.test(s) && origin(s).toLowerCase() !== BASE) throw error("This link belongs to a different website.");
        var match = s.match(/\/(?:anime|watch)\/([a-z\d_-]+)(?:[/?#]|$)/i);
        var slug = match ? match[1] : s.match(/^[a-z\d][a-z\d_-]*$/i) ? s : "";
        if (!slug) throw error("Invalid anime link.");
        var audio = (s.match(/[?&]lang=(sub|dub)(?:&|#|$)/i) || [])[1];
        var episode = (s.match(/[?&]ep=(\d+(?:\.\d+)?)(?:&|#|$)/) || [])[1];
        var al = (s.match(/[?&]al=(\d+)(?:&|#|$)/) || [])[1];
        return { slug: slug, audio: audio ? audio.toLowerCase() : AUDIO, episode: numeric(episode), anilist: numeric(al) };
    }
    function aniListId(item) {
        var n = numeric(item && item.anilist_id);
        if (n > 0) return n;
        var cover = item && item.cover_image || {};
        var match = String(cover.extra_large || cover.large || cover.medium || "").match(/anilist\.co\/.*\/bx(\d+)-/);
        return match ? Number(match[1]) : null;
    }
    function titleOf(item) {
        var t = item.title;
        return plain(typeof t === "string" ? t : t && (t.english || t.romaji || t.native)) || String(item.anime_id || "Untitled");
    }
    function countFor(item, audio) { return numeric(item && item[audio === "dub" ? "dubbed" : "subbed"]); }
    function mediaKey(slug, audio, al, ep) {
        return BASE + (ep === undefined ? "/anime/" : "/watch/") + slug + "?lang=" + audio +
            (ep === undefined ? "" : "&ep=" + ep) + (al > 0 ? "&al=" + al : "");
    }
    async function detail(slug, deadline) {
        var found = detailCache[slug];
        if (found && Date.now() - found.at < CACHE_MS) return found.data;
        var data = await api("/api/v1/anime/" + encodeURIComponent(slug), deadline);
        if (!data || typeof data !== "object" || Array.isArray(data) || (!data.title && !data.anime_id)) throw error("Anime detail response has changed.");
        detailCache[slug] = { at: Date.now(), data: data };
        detailOrder = detailOrder.filter(function (x) { return x !== slug; });
        detailOrder.push(slug);
        while (detailOrder.length > 40) delete detailCache[detailOrder.shift()];
        return data;
    }
    async function search(keyword) {
        var query = String(keyword || "").trim();
        if (!query) return JSON.stringify([]);
        var result = await api("/api/v1/search?q=" + encodeURIComponent(query) + "&limit=10");
        if (!result || !Array.isArray(result.results)) throw error("Search response has changed.");
        var seen = Object.create(null);
        var items = [];
        result.results.forEach(function (item) {
            if (!item || !/^[a-z\d][a-z\d_-]*$/i.test(String(item.anime_id || "")) || seen[item.anime_id]) return;
            if (countFor(item, AUDIO) === 0) return;
            seen[item.anime_id] = true;
            var cover = item.cover_image || {};
            items.push({ title: titleOf(item), image: publicURL(absolute(cover.extra_large || cover.large || cover.medium || "", BASE + "/")),
                href: mediaKey(item.anime_id, AUDIO, aniListId(item)) });
        });
        log("Search returned " + items.length + " titles.");
        return JSON.stringify(items);
    }
    function airdate(item) {
        var value = item.start_date || item.startDate || item.aired || item.release_date;
        if (typeof value === "string") return plain(value).split("T")[0] || "N/A";
        if (value && numeric(value.year) > 0) {
            return String(value.year) + (numeric(value.month) > 0 ? "-" + ("0" + value.month).slice(-2) : "") +
                (numeric(value.month) > 0 && numeric(value.day) > 0 ? "-" + ("0" + value.day).slice(-2) : "");
        }
        return "N/A";
    }
    async function details(key) {
        var data = await detail(keyInfo(key).slug);
        var titles = data.title && typeof data.title === "object" ? data.title : {};
        var values = [titles.english, titles.romaji, titles.native].concat(Array.isArray(data.synonyms) ? data.synonyms : []);
        var aliases = [];
        values.forEach(function (s) { s = plain(s); if (s && aliases.indexOf(s) < 0) aliases.push(s); });
        return JSON.stringify([{ description: plain(data.description || data.synopsis) || "No description provided by ReAnime.",
            aliases: aliases.join(" / ") || "N/A", airdate: airdate(data) }]);
    }
    async function episodes(key) {
        var info = keyInfo(key);
        var results = await Promise.all([
            api("/api/v1/anime/" + encodeURIComponent(info.slug) + "/episodes?limit=2000"),
            detail(info.slug).catch(function () { log("Detail unavailable; episode list will use available metadata."); return null; })
        ]);
        if (!results[0] || !Array.isArray(results[0].data)) throw error("Episode response has changed.");
        var count = countFor(results[1], info.audio);
        var al = aniListId(results[1]) || info.anilist;
        var seen = Object.create(null);
        var items = [];
        results[0].data.forEach(function (ep) {
            var n = numeric(ep && ep.episode_number);
            if (n === null || seen[String(n)] || count === 0 || (count !== null && n > count)) return;
            seen[String(n)] = true;
            items.push({ number: n, href: mediaKey(info.slug, info.audio, al, n) });
        });
        items.sort(function (a, b) { return a.number - b.number; });
        // Explicitly fail on an advertised next page rather than silently implying completeness.
        var meta = results[0].pagination || {};
        if (meta.hasNextPage === true || meta.has_next_page === true) throw error("ReAnime paginated this episode list unexpectedly; module update required.");
        log("Loaded " + items.length + " episodes.");
        return JSON.stringify(items);
    }

    // Restricted literal reader for subtitle metadata only. No eval/Function:
    // it accepts strings, numbers, arrays, objects and simple JS booleans/null.
    function readLiteral(source, offset) {
        var pos = offset || 0;
        var stop = Math.min(source.length, pos + 65536);
        function ws() { while (pos < stop && /\s/.test(source[pos])) pos++; }
        function string() {
            var quote = source[pos++], out = "";
            while (pos < stop) {
                var c = source[pos++];
                if (c === quote) return out;
                if (c !== "\\") { out += c; continue; }
                var escape = source[pos++];
                if (escape === "u" || escape === "x") {
                    var length = escape === "u" ? 4 : 2;
                    var hex = source.slice(pos, pos + length);
                    if (!new RegExp("^[0-9a-f]{" + length + "}$", "i").test(hex)) throw error("Invalid metadata escape.");
                    out += String.fromCharCode(parseInt(hex, 16)); pos += length;
                } else {
                    var map = { n: "\n", r: "\r", t: "\t", b: "\b", f: "\f", v: "\v", "0": "\0" };
                    out += Object.prototype.hasOwnProperty.call(map, escape) ? map[escape] : escape;
                }
            }
            throw error("Unterminated metadata string.");
        }
        function value(depth) {
            if (depth > 12 || pos >= stop) throw error("Metadata exceeds parser limits.");
            ws();
            var c = source[pos];
            if (c === '"' || c === "'") return string();
            if (c === "[" || c === "{") {
                var array = c === "[", out = array ? [] : Object.create(null), closing = array ? "]" : "}";
                pos++; ws();
                if (source[pos] === closing) { pos++; return out; }
                while (pos < stop) {
                    if (array) out.push(value(depth + 1));
                    else {
                        ws(); var property;
                        if (source[pos] === '"' || source[pos] === "'") property = string();
                        else {
                            var key = source.slice(pos, stop).match(/^[a-zA-Z_$][\w$]*/);
                            if (!key) throw error("Invalid metadata property.");
                            property = key[0]; pos += property.length;
                        }
                        ws(); if (source[pos++] !== ":") throw error("Invalid metadata object.");
                        var child = value(depth + 1);
                        if (property !== "__proto__" && property !== "prototype" && property !== "constructor") out[property] = child;
                    }
                    ws();
                    if (source[pos] === closing) { pos++; return out; }
                    if (source[pos++] !== ",") throw error("Invalid metadata separator.");
                    ws(); if (source[pos] === closing) { pos++; return out; }
                }
                throw error("Unterminated metadata collection.");
            }
            var token = source.slice(pos, stop).match(/^(?:true|false|null|undefined|!0|!1|-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/);
            if (!token) throw error("Unsupported metadata expression.");
            pos += token[0].length;
            if (token[0] === "true" || token[0] === "!0") return true;
            if (token[0] === "false" || token[0] === "!1") return false;
            if (token[0] === "null" || token[0] === "undefined") return null;
            return Number(token[0]);
        }
        return { value: value(0), end: pos };
    }
    function attributes(tag) {
        var result = Object.create(null), re = /([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/g, m;
        while ((m = re.exec(tag))) result[m[1].toLowerCase()] = unescapeHTML(m[2] !== undefined ? m[2] : m[3] !== undefined ? m[3] : m[4]);
        return result;
    }
    function subtitleTracks(html, requests, embedURL, headers) {
        var entries = [], seen = Object.create(null), m;
        var source = String(html || "");
        var re = /(?:["']?subtitles["']?)\s*:\s*(\[)/g;
        while ((m = re.exec(source))) {
            try {
                var parsed = readLiteral(source, re.lastIndex - 1);
                if (Array.isArray(parsed.value)) entries = entries.concat(parsed.value);
                re.lastIndex = parsed.end;
            } catch (_) { /* Other script blocks can contain non-literal metadata. */ }
        }
        var trackTags = source.match(/<track\b[^>]*>/gi) || [];
        trackTags.forEach(function (tag) {
            var a = attributes(tag);
            if (!a.kind || /^(?:subtitles|captions)$/i.test(a.kind)) entries.push({ url: a.src, label: a.label || a.srclang });
        });
        var tracks = [];
        function add(entry) {
            if (!entry || typeof entry !== "object") return;
            if (entry.kind && !/^(?:subtitles|captions)$/i.test(String(entry.kind))) return;
            var url = publicURL(absolute(entry.url || entry.file || entry.src, embedURL));
            if (!url || seen[url] || /thumbnail|storyboard|sprite/i.test(url)) return;
            seen[url] = true;
            tracks.push({ title: plain(entry.label || entry.title || entry.lang || entry.language || entry.name) || "Subtitle " + (tracks.length + 1), url: url, headers: headers });
        }
        entries.forEach(add);
        requests.forEach(function (requestURL) {
            var url = requestString(requestURL);
            if (/\.(?:vtt|srt|ass)(?:[?#]|$)/i.test(url.split("?")[0])) add({ url: url, label: /(?:^|[\/_-])en(?:g|glish)?(?:[._/-]|$)/i.test(url) ? "English" : "" });
        });
        tracks.sort(function (a, b) { return (isEnglish(b.title) ? 1 : 0) - (isEnglish(a.title) ? 1 : 0); });
        return tracks;
    }
    function isEnglish(title) { return /^(?:en(?:[-_]us)?|eng|english)(?:\b|\s|$)/i.test(String(title)); }
    function requestString(value) { return typeof value === "string" ? value : value && (value.url || value.requestUrl) || ""; }
    function mediaKind(url) {
        var path = String(url).split(/[?#]/)[0];
        if (/\.m3u8$/i.test(path)) return "hls";
        if (/\.mp4$/i.test(path)) return "mp4";
        return "";
    }
    function candidates(result, embedURL) {
        var observed = Array.isArray(result.requests) ? result.requests.slice() : [];
        if (result.cutoffUrl) observed.push(result.cutoffUrl);
        var tags = String(result.html || "").match(/<(?:video|source)\b[^>]*>/gi) || [];
        tags.forEach(function (tag) { var a = attributes(tag); if (a.src) observed.push(a.src); });
        var seen = Object.create(null), out = [];
        observed.forEach(function (item) {
            var url = publicURL(absolute(requestString(item), embedURL));
            if (!url || seen[url] || !mediaKind(url)) return;
            if (/doubleclick|googlesyndication|\/ads?\/|\/preroll\//i.test(url)) return;
            seen[url] = true; out.push(url);
        });
        function rank(url) {
            return (mediaKind(url) === "hls" ? 0 : 10) + (/\/(?:master|playlist)\.m3u8(?:[?#]|$)/i.test(url) ? 0 : 1);
        }
        return out.sort(function (a, b) { return rank(a) - rank(b); });
    }
    function headerValue(response, name) {
        var headers = response && response.headers;
        if (!headers) return "";
        if (typeof headers.get === "function") return headers.get(name) || "";
        var keys = Object.keys(headers);
        for (var i = 0; i < keys.length; i++) if (keys[i].toLowerCase() === name.toLowerCase()) return String(headers[keys[i]]);
        return "";
    }
    async function verifyMedia(url, embedURL, deadline) {
        var kind = mediaKind(url);
        var headerOptions = [ { Referer: origin(embedURL) + "/", Origin: origin(embedURL) }, { Referer: BASE + "/" }, {} ];
        for (var i = 0; i < headerOptions.length; i++) {
            try {
                var response = await request(url, headerOptions[i], kind === "mp4" ? "HEAD" : "GET", deadline, 5000);
                if (!statusOK(response)) { log("Media check returned HTTP " + (Number(response && response.status) || 0) + "."); continue; }
                if (kind === "hls") {
                    var text = String(await response.text()).replace(/^\uFEFF/, "").trim();
                    if (!/^#EXTM3U(?:\r?\n|$)/.test(text)) { log("Media response is not a plain HLS playlist; native playback cannot use this response."); continue; }
                    // A subtitle playlist is not a playable video source.
                    if (!/#EXT-X-STREAM-INF:/.test(text) && /\.(?:vtt|srt)(?:\?|\s|$)/i.test(text)) continue;
                    return { url: url, headers: headerOptions[i], master: /#EXT-X-STREAM-INF:/.test(text) };
                }
                if (/^video\//i.test(headerValue(response, "Content-Type"))) return { url: url, headers: headerOptions[i], master: false };
            } catch (_) {
                if (deadline - Date.now() < 250) throw error("Playback lookup timed out.");
            }
        }
        return null;
    }
    async function captureServer(server, deadline, audio) {
        audio = audio || AUDIO;
        var embedURL = publicURL(absolute(server.dataLink, BASE + "/"));
        if (!embedURL) throw error("Server returned an invalid video link.");
        if (mediaKind(embedURL)) {
            var direct = await verifyMedia(embedURL, BASE + "/", deadline);
            if (!direct) throw error("The direct media link is unavailable.");
            return { streams: [{ title: audio.toUpperCase() + " · " + String(server.serverName || "Direct"), streamUrl: direct.url, headers: direct.headers }], subtitle: "", allSubtitles: [] };
        }
        if (typeof networkFetch !== "function") throw error("This ShiroX build does not provide networkFetch, which this player requires.");
        // Match the public website's player option. Preserve all other parameters.
        var playerURL = embedURL;
        if (/^https:\/\/(?:www\.)?flixcloud\.cc\//i.test(embedURL) && !/[?&]autoPlay=/i.test(embedURL)) {
            var hashAt = embedURL.indexOf("#"), fragment = hashAt < 0 ? "" : embedURL.slice(hashAt);
            playerURL = (hashAt < 0 ? embedURL : embedURL.slice(0, hashAt));
            playerURL += (playerURL.indexOf("?") < 0 ? "?" : "&") + "autoPlay=true" + fragment;
        }
        var seconds = Math.min(PLAYER_SECONDS, Math.floor(remaining(deadline, PLAYER_SECONDS * 1000 + 1000) / 1000));
        if (seconds < 2) throw error("Playback lookup timed out.");
        // Let the site's own player resolve its stream inside ShiroX. No copied
        // decryption keys, remote script evaluation in JSCore, or API service.
        var capture = await bounded(networkFetch(playerURL, {
            timeoutSeconds: seconds,
            headers: { Referer: BASE + "/" },
            returnHTML: true,
            returnCookies: false,
            waitForSelectors: ["video"],
            clickSelectors: ['.art-icon-play[aria-label="Play"]', 'button[aria-label="Play"]', '.vjs-big-play-button', '.jw-icon-display'],
            maxWaitTime: 5
        }), remaining(deadline, (seconds + 4) * 1000));
        if (!capture || capture.success === false) throw error("The embedded player could not be loaded. " + safeFailure(capture && capture.error));
        var urls = candidates(capture, embedURL).slice(0, 4);
        log("Player capture: " + (Array.isArray(capture.requests) ? capture.requests.length : 0) + " requests, " + urls.length + " media candidates.");
        if (!urls.length) throw error("The player did not expose an HLS or MP4 stream.");
        var fallback = null, selected = null;
        for (var i = 0; i < urls.length; i++) {
            var checked = await verifyMedia(urls[i], embedURL, deadline);
            if (checked && (checked.master || mediaKind(checked.url) === "mp4")) { selected = checked; break; }
            if (checked && !fallback) fallback = checked;
            // Do not spend the entire budget verifying every quality variant.
            if (fallback && i >= 1) break;
        }
        selected = selected || fallback;
        if (!selected) throw error("Captured media URLs could not be verified as playable video.");
        var embedHeaders = { Referer: origin(embedURL) + "/" };
        var tracks = subtitleTracks(capture.html, Array.isArray(capture.requests) ? capture.requests : [], embedURL, embedHeaders);
        // Prefer English; do not auto-enable an unknown-language track.
        var english = tracks.filter(function (track) { return isEnglish(track.title); })[0];
        return {
            streams: [{ title: audio.toUpperCase() + " · " + String(server.serverName || "Server") + (selected.master ? " · Auto" : ""), streamUrl: selected.url, headers: selected.headers }],
            subtitle: english ? english.url : "",
            subtitleHeaders: english ? english.headers : {},
            allSubtitles: tracks
        };
    }
    async function streams(key) {
        log("Playback lookup started; fetchv2=" + (typeof fetchv2 === "function") + ", networkFetch=" + (typeof networkFetch === "function") + ".");
        var info = keyInfo(key), deadline = Date.now() + STREAM_BUDGET_MS;
        if (info.episode === null) throw error("Open an episode before requesting playback.");
        var al = info.anilist;
        if (!al) {
            try { al = aniListId(await detail(info.slug, deadline)); }
            catch (_) { log("Secondary server lookup unavailable; trying the primary endpoint."); }
        }
        function settle(promise) { return promise.then(function (data) { return { data: data }; }, function (err) { return { error: err }; }); }
        var tasks = [settle(api("/api/watch/" + encodeURIComponent(info.slug) + "/" + info.episode, deadline))];
        if (al > 0) tasks.push(settle(api("/api/flix/" + al + "/" + info.episode, deadline)));
        var responses = await Promise.all(tasks), servers = [], seen = Object.create(null);
        responses.forEach(function (entry, index) {
            if (entry.error) { log((index === 0 ? "Primary" : "Secondary") + " server endpoint failed: " + safeFailure(entry.error)); return; }
            var data = entry.data || {};
            var rows = index === 0 ? data.episode_links : data.success ? data.servers : [];
            if (!Array.isArray(rows)) return;
            rows.forEach(function (row) {
                if (!row || !row.dataLink || [info.audio, "s-" + info.audio].indexOf(String(row.dataType).toLowerCase()) < 0) return;
                var identity = String(row.dataLink) + "|" + String(row.dataType);
                if (!seen[identity]) { seen[identity] = true; servers.push(row); }
            });
        });
        function priority(row) { return row.serverName === "HD-2" ? 0 : row.serverName === "HD-1" ? 1 : 2; }
        servers.sort(function (a, b) { return priority(a) - priority(b); });
        log("Found " + servers.length + " eligible " + info.audio.toUpperCase() + " servers for " + info.slug + " episode " + info.episode + ".");
        if (!servers.length) {
            if (responses.every(function (r) { return !!r.error; })) throw responses[0].error;
            throw error("No " + info.audio.toUpperCase() + " servers are available for this episode.");
        }
        var last;
        for (var i = 0; i < Math.min(servers.length, MAX_SERVERS); i++) {
            try {
                log("Resolving " + String(servers[i].serverName || "server") + " for episode " + info.episode + ".");
                var result = await captureServer(servers[i], deadline, info.audio);
                log("Resolved video with " + result.allSubtitles.length + " subtitle tracks.");
                return JSON.stringify(result);
            } catch (err) {
                last = err;
                log("Server attempt " + (i + 1) + " failed: " + safeFailure(err));
                if (deadline - Date.now() < 2000) break;
            }
        }
        throw error("Playback failed. " + String(last && last.message || "No supported stream was found.").replace(/^ReAnime:\s*/, "") + " See Settings > App Logs in ShiroX.");
    }
    return { search: search, details: details, episodes: episodes, streams: streams, version: VERSION,
        // Pure helpers also make the local test harness reproducible.
        _test: { keyInfo: keyInfo, plain: plain, readLiteral: readLiteral, candidates: candidates, subtitleTracks: subtitleTracks,
            publicURL: publicURL, mediaKind: mediaKind, verifyMedia: verifyMedia, captureServer: captureServer } };
})();

async function searchResults(keyword) { return await ReAnime.search(keyword); }
async function extractDetails(url) { return await ReAnime.details(url); }
async function extractEpisodes(url) { return await ReAnime.episodes(url); }
async function extractStreamUrl(url) {
    try { return await ReAnime.streams(url); }
    catch (err) {
        var message = String(err && err.message || err || "Unknown playback failure").replace(/https?:\/\/[^\s<>"']+/gi, "[URL omitted]").slice(0, 350);
        if (typeof console !== "undefined" && typeof console.error === "function") console.error("[ReAnime 0.1.1] " + message);
        throw new Error(message);
    }
}
