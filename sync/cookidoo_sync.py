"""Baut einen Katalog gut bewerteter Cookidoo-Hauptgerichte in Supabase auf.

Läuft als GitHub Action. Achtung: Das Repo ist öffentlich, die Logs auch.
Deshalb hier nie Zugangsdaten oder Kontoinhalte ausgeben, nur Anzahlen.

  python sync/cookidoo_sync.py --check     # nur Login testen
  python sync/cookidoo_sync.py             # Katalog auffrischen (neue Top-Rezepte dazu)
  python sync/cookidoo_sync.py --push      # Sonntags-Erinnerung verschicken
"""

import asyncio
import datetime as dt
import json
import os
import re
import sys

import aiohttp
import httpx
from cookidoo_api import Cookidoo, CookidooConfig, get_localization_options
from cookidoo_api.helpers import (
    _construct_recipe_url,
    _extract_images_from_descriptive_assets,
    cookidoo_ingredient_from_json,
)

MIN_RATING = 4.5
MIN_RATINGS = 30
MAX_TOTAL_TIME = 100 * 60

# Cookidoo-Kategorien für Hauptgerichte und wie viele davon in den Katalog kommen
MAIN_CATEGORIES = {
    "VrkNavCategory-RPF-004": ("Fleisch", 150),           # Hauptgerichte mit Fleisch
    "VrkNavCategory-RPF-006": ("Vegetarisch", 110),       # Hauptgerichte, vegetarisch
    "VrkNavCategory-RPF-003": ("Nudel und Reis", 90),     # Nudel- und Reisgerichte
    "VrkNavCategory-RPF-005": ("Fisch", 50),              # Hauptgerichte mit Fisch
    "VrkNavCategory-RPF-002": ("Suppe", 50),              # Suppen
}
PAGES_PER_CATEGORY = 15  # à 100 Treffer

# Eigene Filter-Chips in der App
CHIPS = {
    "Pasta": re.compile(r"pasta|nudel|spaghetti|lasagne|penne|tagliatelle|gnocchi|maultasche|spätzle|ravioli|tortellini", re.I),
    "Auflauf": re.compile(r"auflauf|gratin|überbacken|lasagne|moussaka", re.I),
    "Curry & Asiatisch": re.compile(r"curry|asiat|thai|wok|indisch|dal\b|masala|teriyaki|ramen|bowl", re.I),
    "Suppe & Eintopf": re.compile(r"suppe|eintopf|chili|gulasch|ramen", re.I),
}

APP_URL = "https://ii201.github.io/einkaufsliste/"


# ---------- Supabase ----------

class Db:
    def __init__(self) -> None:
        self.base = os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1"
        key = os.environ["SUPABASE_SECRET_KEY"]
        self.http = httpx.Client(headers={"apikey": key, "Content-Type": "application/json"}, timeout=60)

    def get(self, table: str, **params: str) -> list[dict]:
        r = self.http.get(f"{self.base}/{table}", params=params)
        r.raise_for_status()
        return r.json()

    def upsert(self, table: str, rows: list[dict]) -> None:
        for i in range(0, len(rows), 100):
            r = self.http.post(
                f"{self.base}/{table}", content=json.dumps(rows[i:i + 100]),
                headers={"Prefer": "resolution=merge-duplicates,return=minimal"},
            )
            r.raise_for_status()

    def patch(self, table: str, values: dict, **params: str) -> None:
        r = self.http.patch(f"{self.base}/{table}", params=params, content=json.dumps(values))
        r.raise_for_status()

    def delete(self, table: str, **params: str) -> None:
        r = self.http.delete(f"{self.base}/{table}", params=params)
        r.raise_for_status()


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
    await api._ensure_endpoints()
    return api


async def search_top(api: Cookidoo) -> dict[str, dict]:
    """Pro Hauptgericht-Kategorie die beliebtesten Rezepte ab 4,5 Sternen."""
    url = api.api_endpoint / api._path("search:home").format(locale="de")
    hits: dict[str, dict] = {}
    for cat, (label, quota) in MAIN_CATEGORIES.items():
        found: dict[str, dict] = {}
        for page in range(PAGES_PER_CATEGORY):
            raw = await api._request_json("get", url, "search", params={
                "categories": cat, "languages": "de", "limit": "100", "page": str(page),
            })
            data = (raw or {}).get("data") or []
            for h in data:
                if (h.get("rating") or 0) >= MIN_RATING and (h.get("numberOfRatings") or 0) >= MIN_RATINGS \
                        and (h.get("totalTime") or 0) <= MAX_TOTAL_TIME:
                    found.setdefault(h["id"], {"rating": h["rating"], "count": h["numberOfRatings"], "cat": label})
            if len(data) < 100:
                break
        # Beliebteste zuerst: viele gute Bewertungen sagen mehr als eine einzelne 5
        top = sorted(found, key=lambda i: found[i]["count"], reverse=True)[:quota]
        for rid in top:
            hits.setdefault(rid, found[rid])
        print(f"{label}: {len(found)} Top-Rezepte, {len(top)} übernommen")
    return hits


class Details:
    """Nur was wir brauchen – tolerant gegenüber fehlenden Feldern (der Bibliotheks-Parser ist strenger)."""

    def __init__(self, raw: dict, url: str) -> None:
        self.name = raw.get("title") or ""
        self.url = url
        self.thumbnail, self.image = _extract_images_from_descriptive_assets(raw.get("descriptiveAssets") or [])
        self.total_time = next(
            (t.get("quantity", {}).get("value") for t in raw.get("times", []) if t.get("type") == "totalTime"), None
        )
        self.ingredients = []
        for group in raw.get("recipeIngredientGroups", []):
            for ing in group.get("recipeIngredients", []):
                try:
                    self.ingredients.append(cookidoo_ingredient_from_json(ing))
                except Exception:
                    pass


async def details(api: Cookidoo, rid: str) -> tuple[dict, Details] | None:
    url = api.api_endpoint / api._path("recipe:details").format(**api._cfg.localization.__dict__, id=rid)
    try:
        raw = await api._request_json("get", url, "recipe details")
    except Exception:
        return None
    return raw, Details(raw, _construct_recipe_url(api._cfg.localization, rid))


REJECTED: dict[str, int] = {}


def reject(reason: str) -> None:
    REJECTED[reason] = REJECTED.get(reason, 0) + 1


def catalog_row(rid: str, hit: dict, raw: dict, d: Details) -> dict | None:
    categories = [c.get("title", "") for c in raw.get("categories", [])]
    tags = [t.get("name", "").lower() for t in raw.get("tags", [])]
    if not d.name or len(d.ingredients) < 3:
        reject("unvollständig")
        return None
    text = " ".join([d.name] + categories)
    chips = [name for name, rx in CHIPS.items() if rx.search(text)]
    if hit["cat"] == "Suppe" and "Suppe & Eintopf" not in chips:
        chips.append("Suppe & Eintopf")
    if hit["cat"] == "Fleisch" or any("fleisch" in c.lower() or "geflügel" in c.lower() for c in categories):
        chips.append("Fleisch")
    if hit["cat"] == "Fisch" or any("fisch" in c.lower() for c in categories):
        chips.append("Fisch")
    veg = hit["cat"] == "Vegetarisch" or "vegetarisch" in tags or "vegan" in tags \
        or any("vegetarisch" in c.lower() for c in categories)
    return {
        "id": rid,
        "name": d.name,
        "image": d.image or d.thumbnail,
        "thumb": d.thumbnail or d.image,
        "url": d.url,
        "total_time": d.total_time or None,
        "rating": hit["rating"],
        "rating_count": hit["count"],
        "chips": chips,
        "vegetarian": veg,
        "in_catalog": True,
        "source": "katalog",
        "ingredients": [{"name": i.name, "description": i.description or ""} for i in d.ingredients],
        "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }


async def check() -> None:
    async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True)) as session:
        await connect(session)
        print("Login ok")


async def catalog() -> None:
    db = Db()
    known = {r["id"]: r["in_catalog"] for r in db.get("recipes", select="id,in_catalog")}

    async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True)) as session:
        api = await connect(session)
        hits = await search_top(api)

        new_rows, rejected = [], 0
        for rid in hits:
            if known.get(rid):
                continue  # schon im Katalog, nur Bewertung auffrischen
            res = await details(api, rid)
            await asyncio.sleep(0.1)
            if not res:
                reject("Abruf fehlgeschlagen")
            row = catalog_row(rid, hits[rid], *res) if res else None
            if row:
                new_rows.append(row)
            else:
                rejected += 1

    db.upsert("recipes", new_rows)
    for rid, h in hits.items():
        if known.get(rid):
            db.patch("recipes", {"rating": h["rating"], "rating_count": h["count"]}, id=f"eq.{rid}")
    # Was nicht mehr zu den Top gehört, fliegt aus dem Katalog (bleibt aber für alte Vorschläge erhalten)
    stale = [rid for rid, inc in known.items() if inc and rid not in hits]
    for rid in stale:
        db.patch("recipes", {"in_catalog": False}, id=f"eq.{rid}")
    total = len(db.get("recipes", select="id", in_catalog="is.true"))
    print(f"Katalog: {total} Rezepte ({len(new_rows)} neu, {len(stale)} raus, {rejected} aussortiert: {REJECTED})")


def push() -> None:
    from pywebpush import WebPushException, webpush

    db = Db()
    subs = db.get("push_subs", select="endpoint,p256dh,auth")
    payload = json.dumps({
        "title": "Was kochen wir diese Woche?",
        "body": "Stöbert im Katalog und schlagt euch Gerichte vor.",
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


if __name__ == "__main__":
    if "--check" in sys.argv:
        asyncio.run(check())
    elif "--push" in sys.argv:
        push()
    else:
        asyncio.run(catalog())
