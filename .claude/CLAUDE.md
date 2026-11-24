# MinorDLNA

Swiftový mediální server pro macOS (DLNA/UPnP + web, cíl LG webOS 22+). Přehled, build a struktura: `README.md`; pravidla přispívání a vydání: `CONTRIBUTING.md`. Kód, komentáře a commity anglicky/stručně podle zvyklostí repa, vše pro uživatele česky.

## Pravidla

- Texty, dokumentace, commity a PR nikdy nejmenují konkurenční mediální platformy (servery, přehrávače, služby titulků); popisuj funkci neutrálně. Názvy protokolových identifikátorů (`X_MS_MediaReceiverRegistrar`) jsou v pořádku.
- Složky v repu velkým písmenem (výjimka `.github`). Dokumentace jen README, CHANGELOG, SECURITY, CONTRIBUTING; žádné návrhy/plány v souborech.
- Závislosti jen `minor-swift-core` a přibalený LGPL ffmpeg.
- `git push` smíš sám (projekt přepisuje globální zákaz). Keychain z Claude prostředí selhává (-128): `git -c credential.helper= -c credential.helper='!gh auth git-credential' push …`. Tag vydání jen na pokyn.
- Nekonečné/dlouhé příkazy (`yes`, watchery) vždy s `timeout 300` nebo `| head`.
- Testy: `xcodebuild test -scheme MinorDLNA -destination 'platform=macOS,arch=arm64'`; lint `swiftlint lint --strict`. SSDP/multicast testy běží jen mimo sandbox nástroje.

## Pokračování práce

Po každém commitu a větším kroku přepiš paměťový soubor `current-progress.md` (poslední commit, kde práce stojí, konkrétní další krok, neověřené věci). Na „pokračuj“ ho přečti a navaž.
