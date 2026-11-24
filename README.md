# MinorDLNA

Mediální server pro macOS ve Swiftu. Přidáte složky s videi, fotkami a hudbou a aplikace je zpřístupní v domácí síti:

- přes **DLNA/UPnP** televizím a přehrávačům (primárně LG webOS 22+; profily i pro Samsung, Sony, Panasonic, Hisense, Android TV a Roku),
- přes **webové rozhraní** v prohlížeči (např. Safari na iPhonu), včetně přehrávání a ovládání televize.

## Funkce

- Knihovny Filmy, Seriály, Složky, Fotky (vč. HEIC) a Hudba; index v SQLite, složky jsou uložené i jako bookmarky (přežijí přesun nebo přejmenování), změny sleduje FSEvents.
- Přímé přehrávání s přetáčením (`Range`). Co televize nebo prohlížeč neumí, se převede přes ffmpeg: nejdřív bez překódování (remux), jen když nesedí kodeky, kóduje se (VideoToolbox, AAC). Externí titulky `.srt`.
- Webový přehrávač: přímo, nebo HLS (Safari přehrává nativně včetně přetáčení), výběr zvukové stopy a titulků.
- České názvy, popisy a plakáty z Wikidaty a Wikipedie (lze vypnout).
- Přehrát na TV, pokračování od uložené pozice, ovladač.
- Aplikace v liště nabídek (stav serveru, adresa webu, počet klientů a převodů), okno Knihovna, Přehled a Nastavení. Spouštění po přihlášení je volitelné (výchozí vypnuto), během streamování se Mac neuspí.

## Požadavky

- Mac s **Apple Silicon (arm64)**, **macOS 26** nebo novější.
- Při prvním spuštění povolit *Místní síť*, jinak televize server neuvidí. Složky Plocha, Dokumenty, Stažené, externí a síťové disky vyvolají systémový dotaz na oprávnění.

## Instalace

Hotová verze je v [GitHub Releases](https://github.com/novami/minor-dlna/releases) (podepsaná Developer ID, notarizovaná). Aktualizace hlídá `MinorUpdater` ze [minor-swift-core](https://github.com/novami/minor-swift-core): ověří SHA-256, podpis stejného týmu, shodné Bundle ID a vyšší verzi.

**Přechod z verze 1.0:** Bundle ID se změnilo na `cz.novami.minor.dlna`, takže 1.0 se sama neaktualizuje; novou verzi stáhněte ručně a starou ukončete, jinak obě obsadí stejný port. Data se nepřenášejí, knihovny se přidají znovu.

## Sestavení ze zdrojů

Xcode 26+, macOS 26+. Projekt vychází ze šablony [minor-swift-starter](https://github.com/novami/minor-swift-starter); nastavení buildu je v `Config/*.xcconfig`.

```bash
./Scripts/build-ffmpeg.sh                    # LGPL ffmpeg a ffprobe do build/ffmpeg/out (první běh pár minut)
xcodebuild test -scheme MinorDLNA -destination 'platform=macOS,arch=arm64'
swiftlint lint --strict
```

Build aplikace spouští `Scripts/build-ffmpeg.sh` sám (fáze *Build ffmpeg*); hotový výsledek se znovu nepoužije jen při změně skriptu nebo verze.

Data: `~/Library/Application Support/cz.novami.minor.dlna` (nastavení, index), cache `~/Library/Caches/cz.novami.minor.dlna`. Logy: `log stream --predicate 'subsystem == "cz.novami.minor.dlna"'`. Webové rozhraní: `http://localhost:8200/`.

## Struktura

```text
App/           vstupní bod, AppModel, AppDelegate
Core/          Settings, Status, AppPaths, AppLog
  Server/        HTTP server (Network.framework), router, MediaServer, ffmpeg nástroje, PathGuard
  SSDP/          SSDP announce a M-SEARCH
  DLNA/          SOAP, DIDL-Lite, GENA, popisy zařízení, formáty
  Store/         SQLite (systémová knihovna)
Features/      Library, Media, Metadata, Transcode, Renderer (Přehrát na TV), Web, Overview, TV, Settings
Config/        xcconfig: identita aplikace, verze, build
Scripts/       build-ffmpeg.sh
Assets/        zdroj ikony aplikace (icon.svg)
Tests/         XCTest
```

Závislosti: jen [minor-swift-core](https://github.com/novami/minor-swift-core) (`MinorLog`, `MinorKeychain`, `MinorUpdater`) a ffmpeg jako přibalená binárka. Žádné jiné externí knihovny.

## Síť a zabezpečení

Podrobnosti jsou v [SECURITY.md](SECURITY.md). Server přijímá jen klienty z privátních sítí, servíruje jen soubory z přidaných knihoven (cesty se rozeberou přes symlinky a porovnají s knihovnou) a webové rozhraní z jiných zařízení je ve výchozím stavu vypnuté, dokud nenastavíte PIN nebo heslo (uložené v Klíčence).

## Licence

Aplikace: MIT.

**ffmpeg:** v aplikaci (`Contents/Helpers/ffmpeg`, `ffprobe`) je ffmpeg 9.0.2 sestavený jako **LGPL v2.1+** (`--disable-gpl --disable-nonfree`, bez libx264 a libx265; video se kóduje přes VideoToolbox). Zdrojové kódy přesné verze: <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz> (SHA-256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`), postup sestavení: [Scripts/build-ffmpeg.sh](Scripts/build-ffmpeg.sh). Text licence je v aplikaci jako `Contents/Resources/FFMPEG-LICENSE.txt`. ffmpeg je spouštěný jako samostatný proces, aplikaci nelinkuje.

## Přispívání a vydání

Viz [CONTRIBUTING.md](CONTRIBUTING.md).
