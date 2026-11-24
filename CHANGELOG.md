# Changelog

## 1.1.0

- Aplikace stojí na společné základně [minor-swift-core](https://github.com/novami/minor-swift-core) a šabloně minor-swift-starter: Xcode projekt, `Config/*.xcconfig`, CI, vydání a aktualizace z reusable workflows; logování `MinorLog`, heslo webu v Klíčence (`MinorKeychain`), aktualizace `MinorUpdater`.
- **Nové Bundle ID `cz.novami.minor.dlna`** (dříve `cz.minordlna.app`). Verze 1.0 se sama neaktualizuje a data se nepřenášejí.
- HTTP server a SSDP na Network.framework (`NetworkListener`), bez Hummingbird, SwiftNIO a dalších knihoven; SSDP multicast přes BSD sokety, protože Network.framework bez entitlementu multicast nedoručuje.
- ffmpeg je přibalený (LGPL build z oficiálního zdroje, `Scripts/build-ffmpeg.sh`), už se nehledá v Homebrew. Bez libx264: video se kóduje jen přes VideoToolbox, volba „Převádět hardwarově“ zmizela.
- Přísnější ochrana: soubor mimo knihovny se neservíruje (symlinky se rozeberou), limity hlaviček a těla, 403 na `..` v cestě, webové rozhraní z LAN je vypnuté, dokud se nenastaví PIN nebo heslo (nejméně 6 znaků).
- Knihovny se ukládají i jako bookmarky; přesunutá nebo přejmenovaná složka se najde.
- Během streamování a převodu se Mac neuspí; při ukončení aplikace server pošle `ssdp:byebye` a ukončí ffmpeg.
- Minimálně macOS 26, jen Apple Silicon; testy v XCTest; SwiftLint povinný.
- Odstraněno: vlastní updater s Ed25519, `packaging/`, Makefile, vlastní workflows, `docs/SWIFT.md`.

## 1.0.0

První vydání čistě Swiftové aplikace.
