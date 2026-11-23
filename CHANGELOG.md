# Changelog

## Nevydáno

- Aktualizace: samostatná volba „Automaticky kontrolovat“ a „Automaticky stahovat a instalovat“ (obě ve výchozím stavu zapnuté), sekce Aktualizace v nastavení s aktuální a dostupnou verzí.
- Build jen pro Apple Silicon (arm64). **Pozor:** verze 1.0.0 byla univerzální; Mac s Intel by po automatické aktualizaci novou verzi nespustil a updater by se měl vrátit k předchozí (neověřeno); další verze už na Intelu neběží.
- CI: akce připnuté na SHA, minimální oprávnění, souběžnost, filtr cest, cache klíčovaná verzí Swiftu; Dependabot.
- SwiftLint (`.swiftlint.yml`, `make lint`, job v CI); zdrojáky přeuspořádány do `Core/`, `Services/`, `Features/` (jádro) a `App/`, `Features/` (aplikace).
- Dokumentace: README, SECURITY, CONTRIBUTING.

## 1.0.0

První vydání čistě Swiftové aplikace.
