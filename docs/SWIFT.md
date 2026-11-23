# Přechod na Swift

Rozhodnutí 2026-11-22: MinorDLNA vznikne znovu jako nová aplikace čistě ve Swiftu. Nemá vazbu na Go verzi: nepřebírá data, config ani instalace a uživatelé si ji nastaví znovu. Go verze se nevydává ani neudržuje. Go kód byl smazán v S9 (poslední verze v gitu před commitem 6481d05).

Nativní SwiftUI pro Mac, webové UI pro přehrávač a vzdálený přístup. Stejné repo, minimum macOS 15, Swift 6 (strict concurrency).

## Technologie

| Účel | Volba | Proč |
|---|---|---|
| HTTP server (DLNA, stream, HLS, SOAP, GENA, web API) | **Hummingbird 2** (nad SwiftNIO) | async/await, streamované odpovědi s backpressure (ffmpeg roury, velké soubory), vlastní metody SUBSCRIBE/UNSUBSCRIBE |
| SSDP (UDP multicast 239.255.255.250:1900) | **SwiftNIO** DatagramBootstrap | Network.framework vyžaduje pro multicast entitlement schvalovaný Applem |
| HTTP klient (SOAP na TV, GENA NOTIFY, Wikidata, GitHub) | URLSession | v systému |
| Nastavení | Codable struktura → `settings.json` v Application Support | čitelné, bez závislosti, SwiftUI se na ně váže přes `@Observable` |
| Knihovna, stav sledování, cache metadat | SQLite přes systémové `SQLite3` + tenký vlastní obal, nové schéma | rychlé stránkování Browse a FTS hledání bez závislosti |
| Spouštění při přihlášení | SMAppService | náhrada launchd plistu |
| Logování | os.Logger (subsystem cz.minordlna.app) | Console.app / `log stream` |
| Aktualizace | vlastní kontrola GitHub Releases, ověření podpisu, výměna bundlu | jako dnes, bez Sparkle |

Range a TimeSeekRange s hlavičkami DLNA.ORG_* napíšeme sami. Přímo použité balíčky: Hummingbird, SwiftNIO, swift-http-types, swift-log, swift-service-lifecycle (poslední tři jsou závislosti Hummingbirdu). ffmpeg a ffprobe zůstávají z Homebrew.

## Struktura

```
macos/
  Package.swift            MinorCore (knihovna), MinorDLNA (SwiftUI app), testy; bez .xcodeproj,
                           bundle skládá packaging/build-app.sh (bundle ID cz.minordlna.app)
  Sources/MinorCore/       Settings, Store, Library, Media, Metadata, Transcode, Stream,
                           SSDP, UPnP (DMS, DMC), Web, Update
  Sources/MinorDLNA/       MenuBarExtra, okna Přehled/Nastavení, NSOpenPanel, SMAppService
  Resources/web/           webové UI (přehrávač, vzdálený přístup)
```

## Fáze

| # | Obsah | Hotovo, když |
|---|---|---|
| S1 | Kostra: SwiftPM, MenuBarExtra, Settings, logování, build-app.sh a podpis, CI | App se spustí z lišty a uloží nastavení |
| S2 | HTTP + SSDP + device.xml + CDS Browse nad složkami + direct play s Range + GENA | LG server vidí a přehraje MKV/MP4 |
| S3 | Store, Library (scanner, FSEvents, parser názvů), Media (ffprobe, EXIF, tagy, náhledy, HEIC) | Filmy/Seriály/Hudba/Fotky na TV, 10k položek plynule |
| S4 | Transcode: profily, rozhodování, VideoToolbox, MPEG-TS, TimeSeekRange, titulky | Převod, posun a titulky na LG |
| S5 | Přehled + Nastavení ve SwiftUI, web API + vzdálený přístup s přihlášením, updater | Nastavení bez prohlížeče, update z vydání na vydání |
| S6 | Metadata (Wikidata/Wikipedie, plakáty, ruční oprava) | Plakáty a české názvy na TV |
| S7 | Přehrát na TV (discovery, AVTransport, pozice, další epizoda, WoL) | Ovládání LG z aplikace i webu |
| S8 | Webový přehrávač: fMP4, HLS master, HDR tónování, Dolby Vision | iPhone a Safari |
| S9 | Profily dalších značek TV, smazání Go kódu, vydání v1.0.0 | Checklist NAVRH §12 na LG |

Testy jsou nové ve Swift Testing, jen pro hlavní cestu a důležité okrajové případy (parser názvů, rozhodování převodu, DIDL, Range).

## Rizika

- **Ztráta ověřených obezliček:** přepis může přijít o obezličky pro LG a iOS (TimeSeekRange 60s timeout, HLS master s CODECS, HDR tónování, DV P5). Než se modul napíše, projde se jeho Go kód jako reference.
- **Žádná funkční verze:** Go verze se neudržuje, takže do S2 nebude funkční DLNA server.
- **Uživatelé v0.2.x:** updater je na Swift verzi nepřevede, musí ji nainstalovat ručně a ve staré verzi vypnout spouštění při přihlášení (jinak zůstane `~/Library/LaunchAgents/cz.minordlna.plist` a obě verze se poperou o porty).
- **Závislosti:** Hummingbird a SwiftNIO jsou externí balíčky, jejich verze uzamkne Package.resolved.
- **Podpis:** oprávnění Místní síť řeší podpis, ne jazyk. Developer ID je dál doporučené.
