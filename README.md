# Einkaufsliste

Gemeinsame Einkaufsliste für den wöchentlichen Discounter-Einkauf. Läuft auf GitHub Pages, die Daten liegen in Supabase.

- `index.html`: die komplette App
- `supabase.sql`: Datenbank-Setup (einmal im Supabase SQL Editor ausführen)

Zugriff nur mit gemeinsamer PIN. Die erste PIN, die nach dem Setup eingegeben wird, wird festgelegt.

PIN zurücksetzen (im Supabase SQL Editor): `update app_settings set pin_hash = null;`. Danach gilt wieder die nächste eingegebene PIN.
