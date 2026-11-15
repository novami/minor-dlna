# MinorDLNA

DLNA/UPnP mediální server v Go pro sdílení videí, fotek a hudby z Macu do TV (primárně LG webOS).

Stav: fáze 3 – index v SQLite, pohledy Filmy (A–Z, naposledy přidané, podle roku), Seriály (seriál → série → díl), Složky, přímé přehrávání se seekem. Fotky podle data s náhledy (vč. HEIC), hudba podle interpretů, alb a žánrů s obaly. Délku, rozlišení a náhledy videí doplní ffmpeg (`brew install ffmpeg`). Návrh: [docs/NAVRH.md](docs/NAVRH.md).

## Spuštění

```bash
make build
./bin/minordlna -debug
```

První spuštění vytvoří `~/Library/Application Support/MinorDLNA/config.yaml`. Doplňte knihovny a restartujte:

```yaml
libraries:
  - { name: Filmy, type: movies, paths: ["~/Movies"] }
  - { name: Fotky, type: photos, paths: ["~/Pictures/Export"] }
  - { name: Hudba, type: music,  paths: ["~/Music"] }
```

Typy: `movies`, `shows`, `videos`, `photos`, `music`. Na TV: *Domů → Média / Připojená zařízení*.

macOS se při prvním spuštění zeptá na přístup k místní síti – bez povolení TV server neuvidí.

## Licence

MIT
