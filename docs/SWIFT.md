# Přechod na Swift

Rozhodnutí 2026-11-22: aplikace primárně ve Swiftu, přepis čistě ve Swiftu bez Go helperu. Nativní SwiftUI pro Mac, webové UI zůstane pro přehrávač a vzdálený přístup. Stejné repo, minimum macOS 15, Swift 6 (strict concurrency).

Vydaná Go verze (v0.2.x) zůstává v provozu a dostává jen opravy, dokud Swift verze nedosáhne stejných funkcí. Teprve pak vyjde Swift verze jako běžná aktualizace (updater vymění celý bundle).

## Síť a závislosti

| Účel | Volba | Proč |
|---|---|---|
| HTTP server (DLNA, stream, HLS, SOAP, GENA, web API) | **Hummingbird 2** (nad SwiftNIO) | async/await, streamované odpovědi s backpressure (ffmpeg roury, velké soubory), vlastní metody SUBSCRIBE/UNSUBSCRIBE přes swift-http-types, aktivně vyvíjený |
| SSDP (UDP multicast 239.255.255.250:1900) | **SwiftNIO** DatagramBootstrap | Network.framework vyžaduje pro multicast entitlement `com.apple.developer.networking.multicast` schvalovaný Applem; BSD socket přes NIO ho nepotřebuje |
| HTTP klient (SOAP na TV, GENA NOTIFY, Wikidata, GitHub) | URLSession | v systému, umí vlastní metody |
| SQLite | systémové `SQLite3` + tenký vlastní obal | bez závislosti, stejné schéma jako Go |
| YAML config | **Yams** | čtení stávajícího `config.yaml` beze změny |

Range a TimeSeekRange s hlavičkami DLNA.ORG_* si napíšeme sami, protože FileMiddleware z Hummingbirdu je neumí.

## Struktura

```
macos/
  Package.swift            MinorCore (knihovna), minordlna (CLI pro testy/serve), testy
  MinorDLNA.xcodeproj      app target (SwiftUI) nad MinorCore
  Sources/MinorCore/       Config, Store, Library, Media, Metadata, Transcode, Stream,
                           SSDP, UPnP (DMS, DMC), Web, Update
  Sources/MinorDLNA/       MenuBarExtra, okna Přehled/Nastavení, NSOpenPanel, SMAppService
  Resources/web/           statické webové UI z internal/web/static
```

Při přechodu se zachová stejné schéma DB, config a cesty (~/Library/Application Support, Logs), takže existující instalace přejde bez ztráty dat.

## Fáze

| # | Obsah | Hotovo, když |
|---|---|---|
| S1 | Kostra: SwiftPM + Xcode, MenuBarExtra, Config (Yams), logování, build-app.sh a podpis, CI | App se spustí z lišty, načte stávající config |
| S2 | HTTP (Hummingbird) + SSDP (NIO) + device.xml + CDS Browse nad složkami + direct play s Range | LG server vidí a přehraje MKV/MP4 |
| S3 | Store, Library (scanner, FSEvents, parser názvů), Media (ffprobe, EXIF, tagy, náhledy, HEIC), GENA | Pohledy Filmy/Seriály/Hudba/Fotky na TV, 10k položek plynule |
| S4 | Transcode: profily, rozhodování, VideoToolbox, MPEG-TS, TimeSeekRange, titulky | Checklist NAVRH §12 (převod) na LG |
| S5 | Nativní Přehled + Nastavení ve SwiftUI, web API + vzdálený přístup s přihlášením, updater | Nastavení bez prohlížeče, update z vydání na vydání |
| S6 | Metadata (Wikidata/Wikipedie, plakáty, ruční oprava) | Shodné párování na vzorku jako Go |
| S7 | Přehrát na TV (DMC: discovery, AVTransport, pozice, další epizoda, WoL) | Ovládání LG z aplikace i webu |
| S8 | Webový přehrávač: fMP4, HLS master, HDR tónování, Dolby Vision | iPhone a Safari jako u Go verze |
| S9 | Profily dalších značek TV, odstranění Go, vydání v0.3.0 | Celý checklist §12, Go smazáno |

Před přepisem každého modulu se jeho testy z Go převedou do Swift Testing (zvlášť parser názvů, rozhodování převodu, DIDL, protocolInfo). U S2–S4 a S8 porovnáme odpovědi Swift a Go serveru na stejné požadavky.

## Rizika

- **Nefunkční verze:** do S9 neexistuje vydatelná Swift verze a souběžné opravy v Go se musí přenést do Swiftu.
- **Ztráta obezliček:** přepis může přijít o ověřené obezličky pro LG a iOS (TimeSeekRange, HLS master, HDR). Ochranou je převod testů a porovnání odpovědí.
- **Závislosti:** Hummingbird + SwiftNIO + Yams jsou tři externí balíčky. Jejich verze uzamkne Package.resolved.
- **Podpis:** oprávnění Místní síť a ikonu v Launch Services řeší podpis, ne jazyk. Developer ID je dál doporučené.
- **Spouštění při přihlášení:** se SMAppService nahradí dnešní launchd plist. Při přechodu je potřeba starý agent odinstalovat.
