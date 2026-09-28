"""Opt-in read-only contract probe. Never print signed media URLs or headers.

Usage: python3 scripts/probe_sources.py --live
This verifies API responses and a media header, not video decoding/device playback.
"""
import argparse
import json
import sys
import urllib.parse
import urllib.request

def request(url, payload=None, headers=None):
    data = json.dumps(payload).encode() if payload else None
    merged = {'Accept': 'application/json', **(headers or {})}
    if data: merged['Content-Type'] = 'application/json'
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=merged), timeout=20) as response:
        return response.read(2_000_000)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()
    if not args.live:
        parser.error('Pass --live to make the small number of public source requests.')
    failures = 0
    try:
        j = json.loads(request('https://graphql.anilist.co', {'query': '{Page(page:1,perPage:10){media(type:ANIME,sort:TRENDING_DESC,isAdult:false){id}}}'}))
        count = len(j['data']['Page']['media'])
        assert count > 0
        print(f'AniList: {count} trending records received.')
    except Exception as e:
        print('AniList probe failed:', type(e).__name__)
        failures += 1
    try:
        query = 'query($query:String,$limit:Int){catalogAnime(filter:{query:$query},limit:$limit){items{id anilistId titleEnglish}}}'
        j = json.loads(request('https://graphql.animex.one/graphql', {'query': query, 'variables': {'query': 'Solo Leveling', 'limit': 2}}))
        rows = j['data']['catalogAnime']['items']
        assert rows, 'No catalog results'
        print(f'Animex: {len(rows)} search records received.')
        base = 'https://pp.animex.one/rest/api/'
        slug = str(rows[0]['id'])
        providers = json.loads(request(base + 'servers?' + urllib.parse.urlencode({'id': slug, 'epNum': 1})))['subProviders']
        assert providers, 'No sub providers'
        response = json.loads(request(base + 'sources?' + urllib.parse.urlencode({'id': slug, 'epNum': 1, 'type': 'sub', 'providerId': providers[0]['id']})))
        sources = response.get('sources', [])
        assert sources, 'No media sources'
        media = sources[0]['url']
        parsed = urllib.parse.urlparse(media)
        assert parsed.scheme == 'https' and parsed.hostname and parsed.username is None
        if parsed.path.endswith('.m3u8'):
            body = request(media, headers=response.get('headers', {}))
            assert body.lstrip(b'\xef\xbb\xbf \r\n').startswith(b'#EXTM3U'), 'Not a plain HLS playlist'
            print('Animex: one plain HLS playlist received; decoding/offline playback NOT tested.')
        else:
            print('Animex: a media URL was returned; media format and playback NOT verified.')
    except Exception as e:
        print('Animex probe failed:', type(e).__name__)
        failures += 1
    return min(failures, 1)

if __name__ == '__main__': sys.exit(main())
