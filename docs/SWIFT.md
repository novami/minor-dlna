# Přechod na Swift

Rozhodnutí 2026-11-22: aplikace primárně ve Swiftu, přechod postupně. Nativní SwiftUI pro Mac, webové UI zůstane pro přehrávač a vzdálený přístup. Stejné repo, minimum macOS 15, Swift 6 (strict concurrency).

## Cílová podoba

```
MinorDLNA.app (Swift)
├─ App        SwiftUI: MenuBarExtra, okno Přehled/Nastavení, výběr složek, přihlášení při startu (SMAppService)
├─ Core       Swift balíčky: Config, Store (SQLite), Library, Media (ffprobe), Metadata, Transcode,
│             Stream, SSDP, UPnP (DMS + DMC), Web (REST + statické soubory), Update
└─ Resources  web/static (přehrávač, vzdálené UI), ikona, lokalizace cs
ffmpeg/ffprobe dál z Homebrew.
```

Server v Go do dokončení přepisu běží jako pomocný proces uvnitř bundlu (`Contents/Helpers/minordlna`), aplikace s ním mluví přes stávající lokální REST API (`/api/state`, `/api/config`, …). Každý přepsaný modul nahradí část Go; Go se smaže až po posledním.

## Fáze

| # | Obsah | Hotovo, když |
|---|---|---|
| S1 | Xcode/SwiftPM projekt v `macos/`, SwiftUI aplikace s lištou, spouští a hlídá Go helper, Přehled + Nastavení nativně přes REST, výběr složek, build-app.sh a podpis pro nový bundle | Nainstalovaná app funguje jako dnes, Go bez systray/cgo |
| S2 | Aktualizace ve Swiftu (GitHub Releases, ověření podpisu, výměna bundlu) | Update z vydání na vydání |
| S3 | Store + Config + Library + Media (scanner, FSEvents, ffprobe, EXIF/tagy, náhledy) | Stejná DB, testy parseru názvů převzaté z Go |
| S4 | Metadata (Wikidata/Wikipedie, plakáty) | Shodné párování na vzorku |
| S5 | HTTP server (Hummingbird nebo SwiftNIO) + Stream (Range, TimeSeekRange) + Web API + statické UI | Webový přehrávač a vzdálené UI na Swift serveru |
| S6 | Transcode (profily, rozhodování, ffmpeg sessions, HLS, HDR/DV logika) | Testy rozhodování převzaté z Go, iPhone/Safari |
| S7 | SSDP + UPnP DMS (device.xml, CDS, CMS, GENA) | LG vidí server, Browse 10k položek |
| S8 | DMC Přehrát na TV + profily značek, odstranění Go | Checklist §12 NAVRH na LG |

Každá fáze končí funkčním vydáním.

## Rizika

- Přepis ztratí ověřené LG/iOS obezličky (TimeSeekRange, HLS master, HDR) — proto převod Go testů do Swift Testing před přepisem modulu a porovnání odpovědí obou serverů.
- HTTP server: Swift nemá ve stdlib; Hummingbird/SwiftNIO = závislost, Network.framework = víc vlastního kódu.
- Místní síť (oprávnění) a ikona v Launch Services řeší podpis, ne jazyk; Developer ID dál doporučen.
- Během S1–S7 dva jazyky v jednom bundlu a CI (Go + Xcode).
