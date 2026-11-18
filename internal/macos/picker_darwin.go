package macos

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Cocoa
#import <Cocoa/Cocoa.h>
#include <stdint.h>
#include <stdlib.h>

extern void pickFolderDone(uintptr_t h, char *path);

// Runs on the main thread, where the menu bar icon's Cocoa loop already runs. The panel lives in
// this process, so it follows the bundle's localization instead of an unlocalized helper's.
static void pickFolder(uintptr_t h, const char *prompt) {
	NSString *msg = [NSString stringWithUTF8String:prompt];
	dispatch_async(dispatch_get_main_queue(), ^{
		NSOpenPanel *panel = [NSOpenPanel openPanel];
		panel.canChooseFiles = NO;
		panel.canChooseDirectories = YES;
		panel.canCreateDirectories = YES;
		panel.allowsMultipleSelection = NO;
		panel.message = msg;
		panel.prompt = @"Vybrat";
		[NSApp activateIgnoringOtherApps:YES];
		[panel beginWithCompletionHandler:^(NSModalResponse r) {
			pickFolderDone(h, r == NSModalResponseOK ? (char *)panel.URL.fileSystemRepresentation : NULL);
		}];
	});
}
*/
import "C"

import (
	"context"
	"runtime/cgo"
	"strings"
	"unsafe"
)

//export pickFolderDone
func pickFolderDone(h C.uintptr_t, path *C.char) {
	hd := cgo.Handle(h)
	ch := hd.Value().(chan string)
	hd.Delete()
	if path == nil {
		close(ch)
		return
	}
	ch <- C.GoString(path)
}

// PickFolder shows the native folder picker on the Mac's screen and returns the chosen path.
// It needs the Cocoa loop on the main thread (tray.Run).
func PickFolder(ctx context.Context, prompt string) (string, error) {
	ch := make(chan string, 1)
	cp := C.CString(prompt)
	defer C.free(unsafe.Pointer(cp))
	C.pickFolder(C.uintptr_t(cgo.NewHandle(ch)), cp)
	select {
	case p, ok := <-ch:
		if !ok {
			return "", ErrCancelled
		}
		return strings.TrimSuffix(p, "/"), nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}
