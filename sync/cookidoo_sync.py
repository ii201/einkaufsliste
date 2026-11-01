"""Holt Rezept-Vorschläge aus Cookidoo und legt sie in Supabase ab.

Läuft als GitHub Action. Achtung: Das Repo ist öffentlich, die Logs auch.
Deshalb hier nie Rezeptnamen, Zugangsdaten oder sonstige Inhalte ausgeben,
nur Anzahlen.

  python sync/cookidoo_sync.py --check   # nur Login testen
"""

import asyncio
import os
import sys

import aiohttp
from cookidoo_api import Cookidoo, CookidooConfig, get_localization_options


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


async def check() -> None:
    async with aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=True)) as session:
        api = await connect(session)
        print("Login ok")
        custom = await api.get_custom_collections()
        managed = await api.get_managed_collections()
        n_custom = sum(len(ch.recipes) for c in custom for ch in c.chapters)
        n_managed = sum(len(ch.recipes) for c in managed for ch in c.chapters)
        print(f"Eigene Sammlungen: {len(custom)} mit {n_custom} Rezepten")
        print(f"Gespeicherte Sammlungen: {len(managed)} mit {n_managed} Rezepten")
        hits = await api.search_recipes(ratings="5,4", page_size=5)
        print(f"Suche ok: {hits.total} Treffer insgesamt")


if __name__ == "__main__":
    if "--check" in sys.argv:
        asyncio.run(check())
