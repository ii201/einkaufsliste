"""Einmalige Diagnose: Blättern in der Suche und Kategorienamen (nur öffentliche Rezeptdaten, keine Kontodaten)."""
import asyncio
import json

import aiohttp

from cookidoo_sync import connect


async def main() -> None:
    async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True)) as session:
        api = await connect(session)
        url = api.api_endpoint / api._path("search:home").format(locale="de")
        for params in (
            {"query": "Hähnchen", "languages": "de", "ratings": "5", "pageSize": "40", "page": "0"},
            {"query": "Hähnchen", "languages": "de", "ratings": "5", "pageSize": "40", "page": "1"},
            {"query": "Hähnchen", "languages": "de", "pageSize": "40", "page": "0"},
            {"query": "Hähnchen", "languages": "de", "ratings": "5", "limit": "40", "offset": "40"},
            {"query": "Hähnchen", "languages": "de", "ratings": "5", "page": "2"},
        ):
            raw = await api._request_json("get", url, "probe", params=params)
            data = (raw or {}).get("data") or []
            extra = {k: v for k, v in (raw or {}).items() if k != "data" and not isinstance(v, (list, dict))}
            print(json.dumps(params, ensure_ascii=False), "->", len(data), "Treffer, erste ID-Endung:",
                  [h["id"][-3:] for h in data[:3]], "Ratings:", [h.get("rating") for h in data[:5]], "Meta:", extra)
        raw = await api._request_json("get", url, "probe", params={"query": "Auflauf", "languages": "de", "pageSize": "40"})
        cats: dict[str, int] = {}
        for h in (raw or {}).get("data", [])[:25]:
            durl = api.api_endpoint / api._path("recipe:details").format(**api._cfg.localization.__dict__, id=h["id"])
            det = await api._request_json("get", durl, "probe")
            for c in det.get("categories", []) or [{"title": "(keine)"}]:
                cats[c.get("title")] = cats.get(c.get("title"), 0) + 1
        print("KATEGORIEN Auflauf:", json.dumps(cats, ensure_ascii=False))


asyncio.run(main())
