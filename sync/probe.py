"""Einmalige Diagnose: Kategorie-IDs der Hauptgerichte (öffentliche Taxonomie, keine Kontodaten)."""
import asyncio
import json

import aiohttp

from cookidoo_sync import connect


async def main() -> None:
    async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True)) as session:
        api = await connect(session)
        url = api.api_endpoint / api._path("search:home").format(locale="de")
        cats: dict[str, str] = {}
        for q in ("Hähnchen", "Lachs", "Auflauf", "vegetarisch", "Suppe", "Pasta", "Curry"):
            raw = await api._request_json("get", url, "probe", params={"query": q, "languages": "de", "limit": "8"})
            for h in (raw or {}).get("data", [])[:8]:
                durl = api.api_endpoint / api._path("recipe:details").format(**api._cfg.localization.__dict__, id=h["id"])
                det = await api._request_json("get", durl, "probe")
                for c in det.get("categories", []):
                    cats[c.get("id")] = c.get("title")
        print("KAT-IDS:", json.dumps(cats, ensure_ascii=False))
        main = [i for i, t in cats.items() if t and (t.lower().startswith("haupt") or "nudel- und reis" in t.lower() or t.lower() == "suppen")]
        for cid in main:
            raw = await api._request_json("get", url, "probe", params={"categories": cid, "languages": "de", "limit": "100"})
            r2 = await api._request_json("get", url, "probe", params={"categories": cid, "languages": "de", "limit": "100", "page": "1"})
            d1, d2 = (raw or {}).get("data", []), (r2 or {}).get("data", [])
            print("FILTER", cid, "->", len(d1), "Treffer Seite 0,", len(d2), "Seite 1, verschieden:", len({h["id"] for h in d1} ^ {h["id"] for h in d2}) > 0)


asyncio.run(main())
