# Zabezpečení

## Hlášení zranitelností

Zranitelnost nehlaste veřejně v issue. Použijte *Security → Report a vulnerability* v tomto repozitáři na GitHubu (soukromé hlášení). Odpovídám podle možností; MinorDLNA je projekt jednoho autora bez garantované doby reakce.

Podporovaná je vždy poslední vydaná verze.

## Model hrozeb a známá omezení

- Server naslouchá v místní síti bez autentizace (DLNA to nezná); přístup je omezen na privátní sítě. Webové rozhraní je z jiných zařízení chráněné heslem (PBKDF2-SHA256, omezení pokusů), z tohoto Macu bez hesla.
- Aktualizace: HTTPS z GitHub Releases, `checksums.txt` podepsaný Ed25519 (privátní klíč je jen v GitHub Secrets), kontrola SHA-256 a podpisu kódu a bundle ID.
- Aplikace je podepsaná vlastním (self-signed) certifikátem a **není notarizovaná** (chybí Apple Developer ID). Gatekeeper ji proto při prvním ručním stažení nepustí bez potvrzení; podpis aktualizací zajišťuje Ed25519, ne notarizace.
- V repozitáři nejsou žádné klíče ani certifikáty; secrety `MINORDLNA_SIGNING_KEY` a `MINORDLNA_CODESIGN_P12` jsou jen v GitHub Secrets.
