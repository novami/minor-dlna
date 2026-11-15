# MinorDLNA – návrh

Mediální server v Go pro sdílení videí, fotek a hudby z Macu do TV (primárně LG webOS 2022+) přes DLNA/UPnP AV. Cíl: plnohodnotný domácí mediální server bez cloudu – TV používá vestavěný přehrávač (LG: *Média / Připojená zařízení*), k tomu webové rozhraní pro procházení, přehrávání v prohlížeči a spouštění přehrávání na TV.

**Cílové prostředí:** server macOS (Apple Silicon i Intel), klient LG TV 2022 a novější (webOS 22+); ostatní DLNA klienti jako „generic“ profil.

**Repozitář:** https://github.com/novami/minor-dlna (Go modul `github.com/novami/minor-dlna`), licence **MIT**.

**Pravidlo pro texty:** v kódu, UI, dokumentaci ani commitech se neuvádějí názvy konkurenčních mediálních serverů a přehrávačů.

## 1. Rozsah

**MVP (v1)**
- Jedna binárka, běh jako launchd agent, data v `~/Library/Application Support/MinorDLNA`.
- DLNA Media Server: SSDP, ContentDirectory (Browse/Search), streamování se seekem.
- Knihovny: Filmy, Seriály, Videa, Fotky, **Hudba**.
- Index v SQLite, detekce změn podle mtime složek + periodický plný rescan.
- Metadata ze souborů: ffprobe, EXIF, hudební tagy (ID3/Vorbis/MP4).
- **Metadata z TMDb** (plakáty, popisy, žánry, obsazení, seriály) – opt-in, vlastní API klíč.
- Náhledy a odvozená rozlišení fotek, HEIC → JPEG.
- Direct play / částečné / plné transkódování přes ffmpeg s **VideoToolbox** (HW akcelerace Macu).
- Titulky: externí `.srt` k TV i do webového přehrávače.
- **„Přehrát na TV“** – web ovládá LG jako UPnP MediaRenderer (play, pauza, seek, hlasitost, stop).
- **Webový přehrávač** (HLS / přímý MP4) pro video i hudbu.
- **Stav sledování:** zhlédnuto / pokračovat (přesně u „Přehrát na TV“ a webu, odhadem u přehrávání spuštěného z TV).
- Webové UI: knihovna s plakáty, detail, přehrávání, správa knihoven, zařízení, streamy, nastavení, logy.
- **Aktualizace z GitHub Releases:** automatické (výchozí, lze vypnout), jinak tlačítko *Zkontrolovat aktualizace*.

**v2**
- Více uživatelů/profilů, stažení titulků z online databáze, playlisty, synchronizace historie sledování s externí službou, přístup mimo LAN.

**Mimo rozsah:** Windows/Linux jako cílová platforma (kód zůstane přenositelný, ale netestuje se), DRM, živé TV/DVR.

## 2. Architektura

```
             ┌──────────────────── MinorDLNA (1 binárka) ───────────────────┐
 LG TV ◄─SSDP─┤ ssdp       announce + M-SEARCH, discovery rendererů         │
       ◄─SOAP─┤ upnp/dms   device.xml, ContentDirectory, ConnectionManager  │
       ─SOAP─►┤ upnp/dmc   AVTransport + RenderingControl (Přehrát na TV)   │
       ◄─HTTP─┤ stream     direct (Range) | transcode (MPEG-TS) | HLS        │
 Prohlížeč ◄──┤ web        UI + REST API (embed.FS)                          │
              │ library    scanner, watcher, parser názvů, tagy            │
              │ metadata   TMDb klient, cache obrázků                      │
              │ store      SQLite (modernc.org/sqlite, bez cgo)            │
              │ profiles   schopnosti klientů (LG webOS 22+, generic)      │
              └──────────────────────────────────────────────────────────────┘
                       │ ffmpeg / ffprobe (Homebrew), TMDb API (HTTPS)
```

### Struktura projektu

```
cmd/minordlna/main.go        CLI: serve | install | uninstall | scan
internal/config/             YAML + flags, výchozí hodnoty
internal/ssdp/               server (announce/odpovědi) + klient (hledání TV)
internal/upnp/               device description, SOAP router, GENA eventing
internal/upnp/               (CDS, CMS a GENA zatím v jednom balíčku; rozdělit, až naroste)
internal/upnp/dmc/           control point: AVTransport, RenderingControl
internal/didl/               DIDL-Lite (pro Browse i SetAVTransportURI)
internal/dlna/               protocolInfo, DLNA.ORG_* příznaky, hlavičky
internal/library/            scanner, watcher, klasifikace, parser názvů
internal/media/              ffprobe, EXIF, hudební tagy, náhledy, HEIC
internal/metadata/tmdb/      vyhledání, detail, obrázky, rate limit
internal/transcode/          profily klientů, rozhodování, ffmpeg sessions, HLS segmenty
internal/playstate/          pozice, zhlédnuto, pokračovat
internal/store/              schéma, migrace, dotazy
internal/stream/             HTTP handler médií, Range, TimeSeekRange
internal/web/                html/template + htmx, REST API, hls.js
internal/update/             kontrola GitHub Releases, stažení, ověření, výměna binárky
internal/version/            verze vložená při buildu (-ldflags)
.github/workflows/           CI (test, lint), release (build + podpis + upload)
```

## 3. DLNA/UPnP – Media Server

**SSDP**
- Na každém aktivním IPv4 rozhraní (bez loopbacku, `utun*` VPN, `bridge*`): `NOTIFY ssdp:alive` 3× po startu a pak každých 900 s (max-age 1800), `ssdp:byebye` při ukončení.
- Typy: `upnp:rootdevice`, `uuid:<UUID>`, `MediaServer:1`, `ContentDirectory:1`, `ConnectionManager:1`.
- Odpověď na `M-SEARCH` se zpožděním dle `MX`, `LOCATION` s IP rozhraní, kam dotaz přišel.
- UUID trvalé (uložené v konfiguraci).

**Device description** – `friendlyName`, ikony 48/120 px, `dlna:X_DLNADOC>DMS-1.50`, služby CDS + CMS + stub `X_MS_MediaReceiverRegistrar`.

**ContentDirectory:1**
- `Browse` se stránkováním `StartingIndex`/`RequestedCount` a `SortCriteria`.
- `GetSystemUpdateID` + GENA eventing – TV obnoví výpis po změně knihovny.
- `Search` – základní (`upnp:class derivedfrom`, `dc:title contains`).
- Stabilní Object ID (`movies/123`, `music/artist/45`), nikdy cesty na disku.
- DIDL obsahuje TMDb data: `upnp:albumArtURI` (plakát), `upnp:genre`, `dc:description`, `dc:date`; u hudby `upnp:artist`, `upnp:album`, `upnp:originalTrackNumber`.

**Streamování**
- Direct play: `http.ServeContent` (Range, 206, HEAD).
- Hlavičky `transferMode.dlna.org` (Streaming / Interactive pro foto) a `contentFeatures.dlna.org` (`DLNA.ORG_OP=01` byte-seek; u transkódu `OP=10` time-seek, `CI=1`).
- `TimeSeekRange.dlna.org: npt=…` → ffmpeg `-ss`; fallback odhad času z bajtového offsetu.
- Titulky: externí `<video>.srt` nebo `<video>.<jazyk>.srt` (přednost má čeština), hlavička `CaptionInfo.sec`, `<sec:CaptionInfoEx>` v DIDL, `res` s `text/srt`; soubory v CP1250 se posílají převedené do UTF-8. Vestavěné titulky v MKV přehraje TV sama při direct play; při remuxu do MPEG-TS se zahazují (TS textové titulky neunese).

**Fotky** – odvozeniny `JPEG_TN` (160 px), `JPEG_SM` (640×480), `JPEG_LRG` (≤ 4096 px) s aplikovanou EXIF orientací, generované až při prvním požadavku a cachované v `cache/thumbs` (klíč obsahuje mtime+velikost souboru, smazané položky se z cache čistí). JPEG do 4096 px bez rotace se posílá jako originál. HEIC/HEIF převádí systémový `sips` (součást macOS, bez ffmpeg); datum pořízení a rozměry HEIC čte také `sips`. Náhledy videí generuje ffmpeg (snímek v 10 % délky), bez ffmpeg se nenabízejí. Pohledy: Podle data (rok → měsíc, EXIF datum, jinak mtime), Složky.

## 4. Přehrát na TV (control point)

- SSDP M-SEARCH na `urn:schemas-upnp-org:device:MediaRenderer:1`, seznam TV ve web UI (LG je MediaRenderer, pokud má zapnuté *Sdílení obrazovky / DLNA*).
- `SetAVTransportURI` (URL streamu + DIDL metadata) → `Play`; ovládání `Pause`, `Seek` (`REL_TIME`), `Stop`, `SetVolume`/`SetMute` (RenderingControl).
- Stav: GENA `LastChange` + polling `GetPositionInfo`/`GetTransportInfo` každé 2 s → **přesná pozice** do play state, „pokračovat od 1:12:30“ = `Seek` po startu.
- Fronta: další epizoda seriálu automaticky (`SetNextAVTransportURI`, pokud ji TV podporuje; jinak po `STOPPED`).
- Zapnutí TV: Wake-on-LAN (volitelně, MAC adresa TV v nastavení); LG musí mít povolené *Zapnout přes Wi-Fi/LAN*.

## 5. Přehrávání: direct play vs. transkódování

| Situace | Akce |
|---|---|
| Kontejner i kodeky podporované | Direct play (byte-seek, bez zátěže) |
| Video OK, audio ne (TrueHD, DTS-HD MA u řad bez DTS) | `-c:v copy`, audio → EAC3/AC3 |
| Nepodporovaný kontejner (WMV, starší AVI) | Remux / transkód do MPEG-TS |
| Nepodporované video | H.264/HEVC přes `h264_videotoolbox` / `hevc_videotoolbox` |
| Webový prohlížeč | HLS (fMP4 segmenty) s kopií videa, kde to jde; jinak transkód |

**Profil LG webOS 22+ (výchozí, upravitelný v YAML):**
- Kontejnery: MKV, MP4, MOV, TS, AVI, WebM.
- Video: H.264, HEVC (10bit, HDR10, HLG, Dolby Vision profil 5/8 v MP4/MKV), VP9, AV1.
- Audio: AAC, AC3, EAC3 (vč. Atmos), MP3, FLAC, PCM; DTS dle řady (přepínač `dts: true|false`, výchozí `true` pro 2023+).
- Detekce: User-Agent `LGE`/`webOS`/`LG-` → profil LG, ostatní klienti „generic“ (vše direct). Ruční přiřazení profilu k IP přijde s web UI.
- Plán (direct / kopie videa + převod zvuku / převod videa) se kóduje do URL streamu (`/transcode/<id>/copy-ac3.ts`), aby nezávisel na User-Agentu přehrávače, který stream stahuje; neznámé hodnoty se odmítají.
- Zvuk: >2 kanály → AC3 640k 5.1, jinak AAC 192k. Video → H.264 (VideoToolbox, nebo libx264 při `hwaccel: none`), max. 1080p. VP9/AV1 se při nutném remuxu převádí (MPEG-TS je neunese). Hudba ALAC/APE/WMA → FLAC.
- Seek u převáděných streamů jen časový (`TimeSeekRange.dlna.org`, `OP=10`); bajtové rozsahy se nenabízejí, protože velikost výstupu není známá. HDR → SDR tone mapping zatím není.

Správa: jeden ffmpeg proces na stream, ukončení při odpojení (context cancel), limit souběžných transkódů (výchozí 2, při plném limitu čeká 5 s – TV se často hned znovu připojuje), HLS segmenty v dočasné složce s úklidem (fáze 8).

## 6. Knihovna a metadata

**Typy knihoven a pohledy v TV**

| Typ | Pohledy |
|---|---|
| Filmy | Vše A–Z, Naposledy přidané, Pokračovat, Podle žánru, Podle roku, Složky |
| Seriály | Seriál → Sezóna → Epizoda, Pokračovat (další díl), Složky |
| Videa | Podle složek, podle data |
| Fotky | Složky, Rok → Měsíc (EXIF datum, fallback mtime) |
| Hudba | Interpret → Album → Skladba, Alba, Žánry, Složky |

**Parser názvů:** `Film (2019).mkv`, `Film.2019.1080p.x265.mkv` → titul + rok; `Serial S01E02`, `1x02`, `Serial/Season 1/02.mkv` → seriál/sezóna/epizoda. Override přes `.nfo` není v MVP.

**TMDb**
- API v3, autentizace Read Access Token (v4 bearer), jazyk `cs-CZ` s fallbackem `en-US`.
- Párování: film `search/movie` (titul + rok), seriál `search/tv` + `tv/{id}/season/{n}`; skóre shody, při nejistotě položka „nespárováno“ a ruční oprava ve web UI.
- Ukládá: titul, originální titul, popis, rok, žánry, hodnocení, délku, obsazení (top 10), plakát, backdrop; obrázky stažené do lokální cache (velikost `w342`/`w780`).
- Obnova metadat 1× za 30 dní, rate limit klienta ~40 req/s, úplný běh na pozadí, sken nečeká.
- Podmínky TMDb: zobrazit logo a text o použití TMDb ve web UI (sekce O aplikaci).
- Bez API klíče vše funguje s názvy ze souborů.

**Hudba** – tagy přes `dhowden/tag` (ID3v2, FLAC, MP4, OGG), chybějící údaje ze struktury `Interpret/Album/01 Skladba.ext`; obal z tagu nebo `cover`/`folder`/`front.jpg`. Pohledy: Interpreti → Alba → Skladby, Alba, Žánry → Alba, Složky. Formáty pro LG direct: MP3, AAC, FLAC, WAV; ALAC/Opus/APE → FLAC (fáze 4).

**Index (SQLite):** od fáze 2 `library`, `dir` (jen složky s médii), `show`, `item` (soubor + parsované údaje + technické údaje z ffprobe v jedné tabulce), `meta` (SystemUpdateID). Fáze 3 přidala sloupce fotek/hudby do `item` a tabulky `artist`, `album`, `genre`. Další fáze přidají `tmdb_cache`, `image`, `play_state`, `client`, `renderer`. Rescan zapisuje jen změněné soubory (size+mtime). ID objektů (`I<id>`, `D<id>`, `S<id>`) jsou stabilní napříč restarty.

**Detekce změn (místo fsnotify):** fsnotify na macOS používá kqueue s jedním deskriptorem na soubor, což u velkých knihoven narazí na limity. Proto každou minutu `stat` všech známých složek – změněné mtime složky (přidání/smazání/přejmenování) spustí rescan knihovny; soubory mladší 2 min se považují za kopírované a knihovna se zkontroluje znovu. Plný rescan každých 6 h zachytí úpravy souborů na místě. Funguje stejně i na síťových svazcích, bez závislosti.

## 7. Stav sledování

- **Web přehrávač:** pozice posílaná každých 10 s → přesná.
- **Přehrát na TV:** pozice z `GetPositionInfo` → přesná.
- **Spuštěno z TV přes DLNA:** odhad z Range/TimeSeekRange požadavků (poslední servírovaný offset ÷ bitrate); zhlédnuto při > 90 %.
- „Pokračovat“ v TV menu jen jako seznam; skok na pozici z TV menu DLNA neumožňuje – plně funguje přes web / Přehrát na TV.

## 8. Webové UI

- `http://<mac>.local:8200/` – `html/template` + htmx, hls.js pro prohlížeče bez nativního HLS (Safari má nativní), vše v `embed.FS`, bez Node buildu.
- **Uživatelská část:** Domů (Pokračovat, Naposledy přidané), knihovny s plakáty, detail (popis, obsazení, stopy, titulky), tlačítka *Přehrát zde* / *Přehrát na TV* (výběr TV), ovladač TV (pauza, seek, hlasitost), fotky jako mřížka + prohlížeč, hudba s přehrávačem a frontou.
- **Admin část:** knihovny (složky, typ, rescan), TMDb (klíč, nespárované položky, ruční párování), zařízení (TV, profily, WoL), aktivní streamy, nastavení, logy.
- Ochrana: jedno heslo (bcrypt) + session cookie; DLNA endpointy bez hesla (protokol to neumí), volitelný allowlist podsítí.

## 9. Konfigurace a provoz na macOS

```yaml
name: "MinorDLNA"
port: 8200
interfaces: []                 # prázdné = všechna LAN rozhraní
allow: ["192.168.0.0/16"]
libraries:
  - { name: Filmy,   type: movies, paths: ["~/Movies/Filmy"] }
  - { name: Seriály, type: shows,  paths: ["/Volumes/Media/Serialy"] }
  - { name: Fotky,   type: photos, paths: ["~/Pictures/Export"] }
  - { name: Hudba,   type: music,  paths: ["~/Music/FLAC"] }
tmdb:
  token: ""                    # prázdné = vypnuto
  language: cs-CZ
transcode:
  ffmpeg: ""                   # prázdné = PATH, /opt/homebrew/bin
  hwaccel: videotoolbox        # none | videotoolbox
  max_sessions: 2
tv:
  - { name: Obývák, mac: "", profile: lg-webos22 }
updates:
  auto: true                   # false = jen ručně tlačítkem
  channel: stable              # stable | prerelease
  check_interval: 24h
```

- Konfigurace i web UI mění stejný soubor (`config.yaml` v data dir).
- `minordlna install` zkopíruje binárku do `~/Library/Application Support/MinorDLNA/bin` (zapisovatelné → možné aktualizace) a vygeneruje LaunchAgent `~/Library/LaunchAgents/cz.minordlna.plist` (RunAtLoad, KeepAlive) – bez další knihovny.
- Proti uspání Macu: během aktivního streamu běží subproces `caffeinate -i -w <pid>`; navíc doporučit *Probudit pro přístup k síti*.
- ffmpeg z Homebrew (`brew install ffmpeg`), nedistribuuje se s binárkou.
- Build: `GOOS=darwin GOARCH=arm64|amd64`, volitelně universal binárka přes `lipo`.
### Aktualizace z GitHubu

- **Zdroj:** `GET https://api.github.com/repos/novami/minor-dlna/releases/latest` (u kanálu `prerelease` seznam releasů). Bez tokenu – limit 60 req/h na IP stačí; odpověď cachovat s `ETag`.
- **Verze:** SemVer tagy `vX.Y.Z`, porovnání s verzí vloženou při buildu; vývojový build (`dev`) se neaktualizuje.
- **Režim auto (výchozí):** kontrola po startu a každých 24 h; nová verze se stáhne a nainstaluje, **až neběží žádný stream** (jinak odloží). Web UI ukáže poznámky k vydání a výsledek.
- **Režim ručně:** v *Nastavení → Aktualizace* tlačítko *Zkontrolovat aktualizace* → zobrazí dostupnou verzi a changelog → *Nainstalovat*. Přepínač *Automatické aktualizace* tamtéž.
- **Assety releasu:** `minordlna_X.Y.Z_darwin_arm64.tar.gz`, `…_darwin_amd64.tar.gz`, `checksums.txt`, `checksums.txt.sig`.
- **Ověření:** SHA-256 z `checksums.txt` + podpis `checksums.txt` klíčem Ed25519, jehož veřejná část je vložená v binárce (soukromý klíč jen v GitHub Actions secrets). Bez platného podpisu se nic neinstaluje – chrání před podvrženým releasem nebo kompromitovaným účtem bez přístupu ke klíči.
- **Instalace:** stažení do dočasného souboru vedle binárky → ověření → `codesign` ad-hoc se stejným identifierem → atomický `rename` přes původní binárku (stará zůstane jako `minordlna.prev`) → ukončení procesu, launchd (`KeepAlive`) spustí novou verzi.
- **Rollback:** nová verze po startu zapíše „zdravý start“; pokud do 60 s spadne, další spuštění vrátí `minordlna.prev`.
- **Migrace DB** jen dopředné a idempotentní; před migrací záloha `library.db`.
- **Release pipeline:** GitHub Actions na tag `v*` – testy, build obou architektur s `-ldflags "-X …/version.Version=…"`, `checksums.txt`, podpis, upload k releasu, poznámky z commitů.

- **Fotky z aplikace Fotky (Photos.app):** knihovnu `.photoslibrary` nečíst přímo (interní formát) – v MVP jen exportované složky; napojení na Photos je kandidát na v2.

## 10. Závislosti

| Účel | Knihovna |
|---|---|
| HTTP, XML, SOAP | stdlib |
| Multicast | `golang.org/x/net/ipv4` |
| DB | `modernc.org/sqlite` |
| EXIF | `github.com/rwcarlsen/goexif` |
| Hudební tagy | `github.com/dhowden/tag` |
| Zmenšování obrázků | `golang.org/x/image/draw` |
| Konfigurace | `gopkg.in/yaml.v3` |
| Web (frontend) | htmx, hls.js – vendorované soubory v `embed.FS` |

TMDb klient, DLNA vrstva i updater vlastní (několik endpointů, bez SDK).

## 11. Fáze implementace

1. **Kostra DMS:** config, SSDP, device.xml, Browse nad složkami bez DB, direct play s Range, verze v binárce, CI. → *LG server vidí a přehraje MKV/MP4.*
2. **Knihovna:** SQLite, scanner, ffprobe, parser názvů, pohledy Filmy/Seriály/Videa, stránkování, eventing.
3. **Fotky + hudba:** EXIF, odvozeniny, HEIC, náhledy videí; tagy, pohledy Interpret/Album.
4. **Transkódování:** profily, rozhodování, VideoToolbox, MPEG-TS, TimeSeekRange, SRT.
5. **Web UI základ + aktualizace:** přihlášení, knihovny s náhledy, admin, launchd install, release pipeline, updater (auto i ruční).
6. **TMDb:** párování, cache obrázků, ruční oprava, plakáty v TV i webu.
7. **Přehrát na TV:** discovery rendererů, AVTransport, ovladač, play state, další epizoda, WoL.
8. **Webový přehrávač:** direct MP4 / HLS, pozice, titulky, hudební přehrávač.

Každá fáze končí funkčním stavem testovaným na LG TV.

## 12. Testování

- Unit (tabulkové): DIDL/protocolInfo, SSDP parser, parser názvů, rozhodování direct/transcode, TMDb párovací skóre (fixtures, bez sítě).
- Integrace: `httptest` – SOAP Browse, stream (Range, HEAD, TimeSeekRange), falešný MediaRenderer pro AVTransport.
- Updater: falešný GitHub API server (`httptest`) – novější/stejná verze, špatný checksum, špatný podpis, odložení při streamu, rollback.
- Ruční checklist na LG: objevení, 10k+ položek, seek, titulky SRT, HEVC HDR / Dolby Vision, TrueHD film, HEIC fotka, FLAC album, Přehrát na TV + pokračování, WoL.

## 13. Rizika a slabá místa

- **macOS Local Network Privacy:** binárka spuštěná z LaunchAgentu může při prvním multicastu vyvolat dialog nebo být tiše zablokována; nepodepsaná binárka bez stabilního identifikátoru může povolení ztrácet po každém buildu → podepsat (ad-hoc `codesign` s pevným identifierem) a ověřit v fázi 1.
- **Aplikační firewall macOS** může blokovat příchozí spojení – při instalaci návod / `socketfilterfw --add`.
- **Uspání Macu** přeruší stream i viditelnost serveru.
- **Více rozhraní (Wi-Fi + Ethernet + VPN):** chybná IP v `LOCATION` = TV server vidí, ale nepřehraje.
- **LG AVTransport quirky:** některé firmwary odmítají `SetAVTransportURI` bez přesného DIDL `protocolInfo`, nebo nehlásí `LastChange` – proto polling.
- **Pozice u přehrávání spuštěného z TV** je jen odhad.
- **TMDb:** posílá názvy souborů na externí službu (opt-in), chybné párování u obecných názvů, závislost na dostupnosti API.
- **HLS v prohlížeči** u HEVC/Dolby Vision: Chrome/Firefox HEVC neumí spolehlivě → transkód do H.264 (zátěž CPU/GPU).
- **Wi-Fi propustnost** u 4K remuxů – řešení jen kabel nebo nižší bitrate.
- **Samoaktualizace a macOS:** výměna binárky mění její hash → systém může znovu žádat povolení Místní síť / firewallu. Stabilní ad-hoc identifier to zmírní, spolehlivě to vyřeší až podpis Developer ID + notarizace (placený účet Apple). Ztráta podpisového klíče Ed25519 = nutnost ruční reinstalace.
- **Binárka v nezapisovatelném umístění** (`/usr/local/bin` s root vlastníkem) se nedá aktualizovat → instalovat do `~/Library/Application Support/MinorDLNA/bin`, jinak updater jen oznámí novou verzi.
- **Rozsah MVP narostl** (TMDb, control point, web přehrávač, hudba) – zhruba dvojnásobek původního; fáze 1–4 dávají použitelný DLNA server dřív, než vznikne zbytek.
