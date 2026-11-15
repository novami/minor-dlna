//go:build !unix

package ssdp

import "syscall"

func reuseControl(_, _ string, _ syscall.RawConn) error { return nil }
