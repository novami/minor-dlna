# MinorDLNA

DLNA/UPnP mediální server v Go pro sdílení videí, fotek a hudby z Macu do TV (primárně LG webOS).

Stav: fáze 4 – index v SQLite, pohledy Filmy (A–Z, naposledy přidané, podle roku), Seriály (seriál → série → díl), Složky, přímé přehrávání se seekem. Fotky podle data s náhledy (vč. HEIC), hudba podle interpretů, alb a žánrů s obaly. Formáty, které LG neumí (např. TrueHD, DTS, WMV), server převádí přes ffmpeg s hardwarovou akcelerací; externí titulky `.srt` (i v CP1250). Překódování, délku, rozlišení a náhledy videí zajišťuje ffmpeg (`brew install ffmpeg`). Návrh: [docs/NAVRH.md](docs/NAVRH.md).

## Spuštění

```bash
make install-app
```

Sestaví `MinorDLNA.app` a zkopíruje ji do `~/Applications`. Pak ji spusťte z Finderu nebo Spotlightu: aplikace běží na pozadí (bez ikony v Docku, s ikonou v řádku nabídek) a otevře v prohlížeči průvodce prvním nastavením – název serveru, složky s médii (výběr přes okno macOS), DTS a spouštění po přihlášení. Další spuštění otevře nastavení běžícího serveru.

- Nastavení: `~/Library/Application Support/MinorDLNA/config.yaml` (index a cache vedle)
- Logy: `~/Library/Logs/MinorDLNA/minordlna.log`
- Správa: `http://localhost:8200/` – jen z tohoto Macu
- macOS se při prvním spuštění zeptá na přístup k místní síti – bez povolení TV server neuvidí.

- Aktualizace: automaticky z GitHub Releases (lze vypnout), nebo *Přehled → Zkontrolovat aktualizace*. Instalují se jen podepsané verze a nikdy během přehrávání.
- Přístup ke správě z telefonu: *Nastavení → Přístup z jiných zařízení* (heslo).

Pro vývoj: `make run` (server v terminálu, logy na stderr).

## Vydání nové verze

Tag `vX.Y.Z` spustí `.github/workflows/release.yml`: sestaví aplikaci, podepíše `checksums.txt` a vytvoří GitHub Release. Workflow potřebuje secret `MINORDLNA_SIGNING_KEY` (obsah souboru se soukromým klíčem z `go run ./tools/release keygen`) a `MINORDLNA_CODESIGN_P12` (base64 certifikátu z `packaging/codesign-keygen.sh`). Aplikace podepsaná stále stejným certifikátem si po aktualizaci ponechá povolení Místní síť; lokální `make app` ho bere z `~/.config/minordlna/codesign.p12`.

## Licence

MIT
