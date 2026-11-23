# Přispívání

- Sestavení a testy: `make test` (`swift test --package-path macos`). Aplikace: `make app`.
- Cílová platforma je výhradně macOS 15+ na Apple Silicon; Swift 6, bez dalších závislostí, pokud to není nutné.
- Odsazení tabulátory (`.editorconfig`), komentáře stručně a jen tam, kde kód sám nestačí. Nové chování pokryjte malým testem v `macos/Tests/MinorCoreTests`.
- Commit zprávy: malá písmena, minulý čas, jedna logická změna.
- Pull request spouští CI (`.github/workflows/ci.yml`: testy a release build na Apple Silicon runneru s cache `macos/.build`; klíč obsahuje OS, architekturu, verzi Swiftu a hash `Package.swift` + `Package.resolved`). Akce v workflow jsou připnuté na commit SHA; aktualizace navrhuje Dependabot.

## Vydání (jen správce)

1. Aktualizovat `CHANGELOG.md`.
2. `git tag vX.Y.Z && git push origin main vX.Y.Z` – spustí `release.yml`.
3. Workflow vyžaduje secrety `MINORDLNA_SIGNING_KEY` a `MINORDLNA_CODESIGN_P12`; bez certifikátu build záměrně selže (ad-hoc podpis by při aktualizaci zrušil povolení Místní síť).
