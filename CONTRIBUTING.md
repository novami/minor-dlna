# Přispívání

- Sestavení a testy: `xcodebuild test -scheme MinorDLNA -destination 'platform=macOS,arch=arm64'` (první běh sestaví ffmpeg přes `Scripts/build-ffmpeg.sh`). Styl hlídá `swiftlint lint --strict` (konfigurace `.swiftlint.yml`, CI ho spouští se `--strict`).
- Cílová platforma je macOS 26+ na Apple Silicon; Swift 6 se striktní souběžností, výchozí izolace `MainActor`. Síťový a datový kód patří do `Core/` a `Features/` a je `nonisolated` nebo actor. Externí knihovny jen po dohodě; povolený je `minor-swift-core` a přibalený ffmpeg (jen LGPL build).
- Odsazení tabulátory (`.editorconfig`), komentáře stručně a jen tam, kde kód sám nestačí. Nové chování pokryjte malým testem v `Tests/` (XCTest).
- Commit zprávy: malá písmena, minulý čas, jedna logická změna.
- Pull request spouští CI (`.github/workflows/ci.yml`): `lint / swiftlint` a `test / xctest` z minor-swift-core.

## Vydání (jen správce)

1. Zvednout `MARKETING_VERSION` v `Config/Version.xcconfig` (jen `major.minor.patch`) a doplnit `CHANGELOG.md`.
2. Po sloučení do `main`: `git tag X.Y.Z && git push origin X.Y.Z` (tag bez „v“) – spustí `release.yml`.
3. Repozitář musí mít secrety `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` a v `Config/App.xcconfig` `DEVELOPMENT_TEAM`; **bez nich vydání selže.**

## Pojmenování

Složky v repozitáři začínají velkým písmenem (výjimka `.github`). Dokumentace je jen README, CHANGELOG, SECURITY a CONTRIBUTING; historie a návrhy patří do gitu, ne do souborů.
