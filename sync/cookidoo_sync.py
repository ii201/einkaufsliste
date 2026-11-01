"""Holt Rezept-Vorschläge aus Cookidoo und legt sie in Supabase ab.

Läuft als GitHub Action. Achtung: Das Repo ist öffentlich, die Logs auch.
Deshalb hier nie Rezeptnamen, Zugangsdaten oder sonstige Inhalte ausgeben,
nur Anzahlen.

  python sync/cookidoo_sync.py --check   # nur Login testen
  python sync/cookidoo_sync.py           # Vorschläge für die kommende Woche holen
  python sync/cookidoo_sync.py --force   # ... auch wenn es schon welche gibt
  python sync/cookidoo_sync.py --push    # Sonntags-Erinnerung verschicken
"""

import asyncio
import datetime as dt
import json
import os
import random
import re
import sys

import aiohttp
import httpx
from cookidoo_api import Cookidoo, CookidooConfig, get_localization_options

FROM_COLLECTIONS = 10
FROM_SEARCH = 5
COOLDOWN_WEEKS = 4  # gekochte und abgelehnte Rezepte so lange nicht wieder vorschlagen
MAX_TOTAL_TIME = 100 * 60  # keine Festtags-Projekte unter der Woche
# Grundrezepte und Beilagen sind kein Abendessen
# ("Pasta- und Pizzasauce" raus, "Lachs mit Dillsauce" bleibt)
NOT_A_MEAL = re.compile(r"^menü|^(?!.*\bmit\b).*(sauce|soße|dip|pesto|dressing|gewürz\w*|paste|marinade|brühe|fond)$", re.I)
SEARCH_TERMS = [
    "Abendessen", "Hauptgericht", "Pasta", "Curry", "Auflauf", "Suppe", "Risotto",
    "Hähnchen", "vegetarisch", "Reis", "Ofengemüse", "Eintopf", "Lachs", "Gnocchi",
]

APP_URL = "https://ii201.github.io/einkaufsliste/"


# ---------- Supabase ----------

class Db:
    def __init__(self) -> None:
        self.base = os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1"
        key = os.environ["SUPABASE_SECRET_KEY"]
        self.http = httpx.Client(headers={"apikey": key, "Content-Type": "application/json"}, timeout=30)

    def get(self, table: str, **params: str) -> list[dict]:
        r = self.http.get(f"{self.base}/{table}", params=params)
        r.raise_for_status()
        return r.json()

    def upsert(self, table: str, rows: list[dict]) -> None:
        if not rows:
            return
        r = self.http.post(
            f"{self.base}/{table}", content=json.dumps(rows),
            headers={"Prefer": "resolution=merge-duplicates,return=minimal"},
        )
        r.raise_for_status()

    def delete(self, table: str, **params: str) -> None:
        r = self.http.delete(f"{self.base}/{table}", params=params)
        r.raise_for_status()


def next_monday(today: dt.date) -> dt.date:
    return today + dt.timedelta(days=(7 - today.weekday()) % 7 or 7)


# ---------- Cookidoo ----------

async def connect(session: aiohttp.ClientSession) -> Cookidoo:
    loc = (await get_localization_options(country="de", language="de-DE"))[0]
    api = Cookidoo(
        session,
        cfg=CookidooConfig(
            localization=loc,
            email=os.environ["COOKIDOO_EMAIL"],
            password=os.environ["COOKIDOO_PASSWORD"],
        ),
    )
    await api.login()
    return api


async def collection_recipe_ids(api: Cookidoo) -> set[str]:
    ids: set[str] = set()
    for getter in (api.get_custom_collections, api.get_managed_collections):
        page = 0
        while True:
            cols = await getter(page)
            for c in cols:
                for ch in c.chapters:
                    ids.update(r.id for r in ch.recipes)
            if not cols or page >= 10:
                break
            page += 1
    return ids


async def search_recipe_ids(api: Cookidoo, exclude: set[str], wanted: int) -> list[str]:
    found: list[str] = []
    terms = random.sample(SEARCH_TERMS, k=min(4, len(SEARCH_TERMS)))
    for term in terms:
        res = await api.search_recipes(term, languages="de", ratings="5,4", page_size=30, page=random.randint(0, 3))
        hits = [h.id for h in res.recipes if h.id not in exclude and h.id not in found]
        random.shuffle(hits)
        found.extend(hits[: max(1, wanted // len(terms) + 1)])
        if len(found) >= wanted:
            break
    return found[:wanted]


def recipe_row(d, source: str) -> dict:
    return {
        "id": d.id,
        "name": d.name,
        "image": d.image or d.thumbnail,
        "url": d.url,
        "total_time": d.total_time or None,
        "source": source,
        "ingredients": [
            {"name": i.name, "description": i.description or ""} for i in d.ingredients
        ],
        "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }


async def check() -> None:
    async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True)) as session:
        api = await connect(session)
        print("Login ok")
        ids = await collection_recipe_ids(api)
        print(f"Rezepte in Sammlungen: {len(ids)}")
        res = await api.search_recipes("Abendessen", ratings="5,4", page_size=5)
        print(f"Suche ok: {res.total} Treffer insgesamt")
        if res.recipes:
            d = await api.get_recipe_details(res.recipes[0].id)
            print(f"Rezept-Details ok: {len(d.ingredients)} Zutaten, Bild: {'ja' if d.image else 'nein'}")


async def sync(force: bool) -> None:
    db = Db()
    week = next_monday(dt.date.today())
    if not force and db.get("suggestions", select="recipe_id", week=f"eq.{week}"):
        print(f"Für die Woche ab {week} gibt es schon Vorschläge – nichts zu tun.")
        return

    since = (week - dt.timedelta(weeks=COOLDOWN_WEEKS)).isoformat()
    cooked = [r["recipe_id"] for r in db.get("cooked", select="recipe_id", week=f"gte.{since}")]
    disliked = {r["recipe_id"] for r in db.get("votes", select="recipe_id", week=f"gte.{since}", liked="is.false")}
    last_shown = {r["recipe_id"] for r in db.get("suggestions", select="recipe_id", week=f"gte.{(week - dt.timedelta(weeks=1)).isoformat()}")}
    ever_cooked = [r["recipe_id"] for r in db.get("cooked", select="recipe_id")]
    blocked = set(cooked) | disliked | last_shown

    async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True)) as session:
        api = await connect(session)

        pool = [i for i in await collection_recipe_ids(api) if i not in blocked]
        # Was ihr schon mal gekocht habt, kommt öfter dran
        weights = [3 if i in ever_cooked else 1 for i in pool]
        picked: list[str] = []
        while pool and len(picked) < FROM_COLLECTIONS:
            i = random.choices(range(len(pool)), weights=weights)[0]
            picked.append(pool.pop(i))
            weights.pop(i)
        from_collections = set(picked)

        wanted_new = FROM_SEARCH + (FROM_COLLECTIONS - len(picked))
        picked += await search_recipe_ids(api, blocked | from_collections, wanted_new)

        rows = []
        tried = set(picked)
        replacements = 0
        while picked:
            rid = picked.pop(0)
            try:
                d = await api.get_recipe_details(rid)
            except Exception as e:  # einzelne kaputte Rezepte überspringen
                print(f"Rezept übersprungen ({type(e).__name__})")
                continue
            if (d.total_time or 0) > MAX_TOTAL_TIME or NOT_A_MEAL.search(d.name) or len(d.ingredients) < 5:
                # zu aufwendig: durch ein anderes neues Rezept ersetzen
                if rid not in from_collections and replacements < 10:
                    replacements += 1
                    picked += await search_recipe_ids(api, blocked | tried, 1)
                    tried.update(picked)
                continue
            rows.append(recipe_row(d, "sammlung" if rid in from_collections else "neu"))

    random.shuffle(rows)
    db.upsert("recipes", rows)
    db.delete("suggestions", week=f"eq.{week}")
    db.upsert("suggestions", [{"week": week.isoformat(), "recipe_id": r["id"], "position": n} for n, r in enumerate(rows)])
    n_col = sum(r["source"] == "sammlung" for r in rows)
    print(f"Woche ab {week}: {len(rows)} Vorschläge ({n_col} aus Sammlungen, {len(rows) - n_col} neu)")


def push() -> None:
    from pywebpush import WebPushException, webpush

    db = Db()
    subs = db.get("push_subs", select="endpoint,p256dh,auth")
    payload = json.dumps({
        "title": "Was kochen wir diese Woche?",
        "body": "Neue Rezepte sind da – wischt euch durch die Vorschläge.",
        "url": APP_URL + "#kochen",
    })
    sent = 0
    for s in subs:
        try:
            webpush(
                subscription_info={"endpoint": s["endpoint"], "keys": {"p256dh": s["p256dh"], "auth": s["auth"]}},
                data=payload,
                vapid_private_key=os.environ["VAPID_PRIVATE_KEY"],
                vapid_claims={"sub": APP_URL},
                ttl=6 * 3600,
            )
            sent += 1
        except WebPushException as e:
            if e.response is not None and e.response.status_code in (404, 410):
                db.delete("push_subs", endpoint=f"eq.{s['endpoint']}")
            else:
                print(f"Push fehlgeschlagen ({e.response.status_code if e.response is not None else '?'})")
    print(f"Push an {sent} von {len(subs)} Geräten verschickt")


async def probe() -> None:
    """Zeigt Kategorie- und Schlagwort-Namen öffentlicher Rezepte (keine Kontodaten)."""
    async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True)) as session:
        api = await connect(session)
        await api._ensure_endpoints()
        url = api.api_endpoint / api._path("search:home").format(locale="de")
        cats, tags, countries = {}, {}, {}
        for q in ("vegetarisch", "Hähnchen", "Lachs", "Pasta"):
            raw = await api._request_json("get", url, "probe", params={"query": q, "languages": "de", "ratings": "5", "pageSize": "5"})
            for hit in raw.get("data", []):
                rurl = api.api_endpoint / api._path("recipe:details").format(**api._cfg.localization.__dict__, id=hit["id"])
                det = await api._request_json("get", rurl, "probe")
                for c in det.get("categories", []):
                    cats[c.get("title")] = cats.get(c.get("title"), 0) + 1
                for t in det.get("tags", []):
                    tags[t.get("name")] = tags.get(t.get("name"), 0) + 1
                for c in det.get("targetCountries", []):
                    countries[c] = countries.get(c, 0) + 1
        print("KATEGORIEN:", json.dumps(cats, ensure_ascii=False))
        print("TAGS:", json.dumps(dict(sorted(tags.items(), key=lambda x: -x[1])[:40]), ensure_ascii=False))
        print("LAENDER:", json.dumps(countries))


if __name__ == "__main__":
    if "--probe" in sys.argv:
        asyncio.run(probe())
    elif "--check" in sys.argv:
        asyncio.run(check())
    elif "--push" in sys.argv:
        push()
    else:
        asyncio.run(sync(force="--force" in sys.argv))
