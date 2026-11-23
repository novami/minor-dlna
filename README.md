# MinorDLNA

DLNA/UPnP mediální server pro macOS ve Swiftu: sdílí videa, fotky a hudbu z Macu do televize (primárně LG webOS 22+; profily i pro Samsung, Sony, Panasonic, Hisense, Android TV a Roku). Podrobný návrh a historie: [docs/NAVRH.md](docs/NAVRH.md) (původní návrh, částečně zastaralý), [docs/SWIFT.md](docs/SWIFT.md) (přepis do Swiftu).

## Funkce

- Knihovny Filmy, Seriály, Složky, Fotky (vč. HEIC) a Hudba, index v SQLite, sledování složek přes FSEvents.
- Přímé přehrávání s přetáčením; formáty, které TV neumí (TrueHD, DTS, WMV…), se převádějí přes ffmpeg s VideoToolbox. Externí titulky `.srt`.
- České názvy, popisy a plakáty z Wikidaty a Wikipedie (lze vypnout).
- Přehrát na TV, pokračování od uložené pozice, ovladač (včetně webového rozhraní pro telefon, chráněného heslem).
- Aplikace v liště nabídek, okno Knihovna a Přehled, nastavení.

## Požadavky

- Mac s **Apple Silicon (arm64)**, macOS 15 nebo novější. Intel Macy aplikace nepodporuje.
- ffmpeg a ffprobe pro převody a náhledy: `brew install ffmpeg`.
- Povolení *Místní síť* při prvním spuštění, jinak TV server neuvidí.

## Instalace a sestavení

Hotová verze: [GitHub Releases](https://github.com/novami/minor-dlna/releases). Aplikace je podepsaná vlastním certifikátem, **není notarizovaná** – při prvním spuštění je nutné ji v Gatekeeperu povolit (Soukromí a zabezpečení → Přesto otevřít).

Ze zdrojů (Xcode Command Line Tools / Swift 6):

```bash
make install-app   # sestaví dist/MinorDLNA.app a zkopíruje do ~/Applications
make test          # swift test
```

Data: `~/Library/Application Support/cz.minordlna.app` (nastavení, index), cache `~/Library/Caches/cz.minordlna.app`. Logy: `log stream --predicate 'subsystem == "cz.minordlna.app"'`. Webové rozhraní: `http://localhost:8200/`.

## Struktura

```text
macos/Sources/MinorCore    jádro bez UI: DLNA/SSDP/SOAP, Store (SQLite), Library, Media, Transcode,
                           Metadata, Renderer (Přehrát na TV), Web, Update
macos/Sources/MinorDLNA    SwiftUI aplikace (menu lišty, okna, nastavení)
macos/Tests                testy jádra (swift-testing)
packaging                  build .app, podpis, ikona, Info.plist
.github/workflows          CI a vydání
```

Závislosti (jen Swift balíčky, nic dalšího): Hummingbird, SwiftNIO, swift-service-lifecycle, swift-log, swift-http-types. Zbytek jsou systémové frameworky.

## Automatické aktualizace

Vlastní updater nad GitHub Releases (ne Sparkle). V *Nastavení → Aplikace → Aktualizace*:

- *Automaticky kontrolovat aktualizace* (výchozí zapnuto) – kontrola 60 s po startu a pak denně.
- *Automaticky stahovat a instalovat* (výchozí zapnuto) – instaluje se jen mimo běžící převod; po vypnutí se nová verze jen nabídne a uživatel potvrdí *Stáhnout a nainstalovat*.
- *Zkontrolovat* ručně, zobrazení aktuální a dostupné verze a stavu.

Zabezpečení: HTTPS, `checksums.txt` podepsaný Ed25519 (veřejný klíč je v aplikaci), kontrola SHA-256 archivu, shoda bundle ID a ověření podpisu kódu (`codesign --verify`); při nespuštění nové verze se vrátí předchozí. Podepsáno vlastním certifikátem, bez notarizace – viz [SECURITY.md](SECURITY.md).

## Vydání

Tag `vX.Y.Z` spustí `.github/workflows/release.yml`: testy, build, zip, podepsaný `checksums.txt`, GitHub Release. Secrety: `MINORDLNA_SIGNING_KEY` (base64 32bajtového seedu Ed25519) a `MINORDLNA_CODESIGN_P12` (base64 certifikátu z `packaging/codesign-keygen.sh`; stejný certifikát udrží povolení Místní síť napříč aktualizacemi). Více v [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

MIT
