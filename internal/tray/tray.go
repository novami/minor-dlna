// Package tray shows the menu bar icon and its menu.
package tray

import (
	"fmt"
	"sync"
	"time"

	"fyne.io/systray"

	"github.com/novami/minor-dlna/internal/icon"
	"github.com/novami/minor-dlna/internal/macos"
)

// Status is what the menu shows about the running server.
type Status struct {
	Name      string
	Running   bool
	Streams   int
	Scanning  bool
	UpdateVer string // newer version found, empty if none
}

// Actions connect the menu to the server. All may be called from the menu goroutine.
type Actions struct {
	Status        func() Status
	OpenUI        func(tab string)
	Rescan        func()
	CheckUpdate   func() (newVersion string, err error)
	InstallUpdate func()
	ShowLog       func()
	Quit          func()
}

// Run blocks on the main thread (Cocoa requirement) until Stop is called.
func Run(a Actions) {
	systray.Run(func() { onReady(a) }, func() {})
}

// Stop removes the icon and makes Run return.
func Stop() { systray.Quit() }

func onReady(a Actions) {
	systray.SetTemplateIcon(icon.Template(44), icon.Template(44))
	systray.SetTooltip("MinorDLNA")

	title := systray.AddMenuItem("MinorDLNA", "")
	title.Disable()
	status := systray.AddMenuItem("", "")
	status.Disable()
	status.Hide()
	systray.AddSeparator()
	open := systray.AddMenuItem("Otevřít správu…", "Nastavení a přehled v prohlížeči")
	lib := systray.AddMenuItem("Procházet knihovnu…", "Knihovna s náhledy v prohlížeči")
	rescan := systray.AddMenuItem("Prohledat knihovny znovu", "Najde nové a smazané soubory hned")
	systray.AddSeparator()
	install := systray.AddMenuItem("", "")
	install.Hide()
	check := systray.AddMenuItem("Zkontrolovat aktualizace", "")
	systray.AddSeparator()
	autostart := systray.AddMenuItemCheckbox("Spouštět po přihlášení", "", macos.AutostartEnabled())
	logs := systray.AddMenuItem("Zobrazit protokol", "Otevře záznam činnosti serveru v Konzoli")
	systray.AddSeparator()
	quit := systray.AddMenuItem("Ukončit MinorDLNA", "TV přestane vidět vaše média")

	var mu sync.Mutex
	refresh := func() {
		mu.Lock()
		defer mu.Unlock()
		s := a.Status()
		if s.Running {
			title.SetTitle(fmt.Sprintf("%s – běží", s.Name))
		} else {
			title.SetTitle("MinorDLNA – spouštím…")
		}
		switch {
		case s.Streams > 0:
			status.SetTitle(fmt.Sprintf("Přehrává se: %d", s.Streams))
			status.Show()
		case s.Scanning:
			status.SetTitle("Prohledávám knihovny…")
			status.Show()
		default:
			status.Hide()
		}
		if s.UpdateVer != "" {
			install.SetTitle("Nainstalovat verzi " + s.UpdateVer)
			install.Show()
		} else {
			install.Hide()
		}
		if macos.AutostartEnabled() {
			autostart.Check()
		} else {
			autostart.Uncheck()
		}
	}
	refresh()

	go func() {
		tick := time.NewTicker(3 * time.Second)
		defer tick.Stop()
		for {
			select {
			case <-tick.C:
				refresh()
			case <-open.ClickedCh:
				a.OpenUI("")
			case <-lib.ClickedCh:
				a.OpenUI("library")
			case <-rescan.ClickedCh:
				a.Rescan()
				refresh()
			case <-check.ClickedCh:
				check.SetTitle("Kontroluji…")
				check.Disable()
				go func() {
					v, err := a.CheckUpdate()
					switch {
					case err != nil:
						check.SetTitle("Kontrola selhala – zkusit znovu")
					case v == "":
						check.SetTitle("Máte nejnovější verzi")
					default:
						check.SetTitle("Zkontrolovat aktualizace")
					}
					check.Enable()
					refresh()
				}()
			case <-install.ClickedCh:
				install.SetTitle("Instaluji…")
				install.Disable()
				a.InstallUpdate()
			case <-autostart.ClickedCh:
				_ = macos.SetAutostart(!autostart.Checked())
				refresh()
			case <-logs.ClickedCh:
				a.ShowLog()
			case <-quit.ClickedCh:
				a.Quit()
				return
			}
		}
	}()
}
