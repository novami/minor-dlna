# Zabezpečení

## Hlášení zranitelností

Zranitelnost nehlaste veřejně v issue. Použijte *Security → Report a vulnerability* v tomto repozitáři na GitHubu (soukromé hlášení). Odpovídám podle možností; MinorDLNA je projekt jednoho autora bez garantované doby reakce.

Podporovaná je vždy poslední vydaná verze.

## Model hrozeb a známá omezení

- Server naslouchá v místní síti bez autentizace (DLNA to nezná). Každé spojení z adresy mimo privátní, link-local a loopback sítě se hned odmítne; aplikace nic neotevírá na routeru ani v internetu.
- Servírují se a ffmpegu se předávají jen soubory z přidaných knihoven. Cesta se převede na skutečnou (symlinky, `..`), ověří se, že leží uvnitř knihovny, a požadavky s `..` v cestě dostanou 403. Soubory se streamují po částech.
- Limity: hlavička do 16 kB a 64 polí, tělo do 1 MB, URI do 4 kB, nejvýš 64 souběžných spojení, časové limity čtení požadavku, souběžné převody jsou omezené (výchozí 2). ffmpeg se spouští přes `Process` s pevným polem argumentů, nikdy přes shell.
- Webové rozhraní je z jiných zařízení **ve výchozím stavu vypnuté**. Po zapnutí vyžaduje PIN nebo heslo (PBKDF2-SHA256, uložený hash v Klíčence, omezení pokusů a blokace); z tohoto Macu (loopback) funguje bez přihlášení.
- Aktualizace: `MinorUpdater` stahuje z GitHub Releases přes HTTPS, ověřuje SHA-256, podpis Developer ID stejného týmu, Bundle ID a vyšší verzi.
- Aplikace je podepsaná Developer ID, s hardened runtime a notarizovaná; bez sandboxu (musí číst libovolné složky a poslouchat v síti). ffmpeg a ffprobe jsou přibalené, podepsané stejným certifikátem a nic se nestahuje za běhu.
- V repozitáři nejsou žádné klíče ani certifikáty; secrety pro vydání jsou jen v GitHub Secrets.
- Logy (`os.Logger`) neobsahují na úrovni info celé cesty k souborům; cesty a příkazy ffmpegu jsou jen na úrovni debug a v ostrém sestavení se maskují.
