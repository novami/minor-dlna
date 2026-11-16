// Command release manages the Ed25519 key that signs release checksums.
//
//	go run ./tools/release keygen <private-key-file>   prints the public key to embed in internal/update
//	go run ./tools/release sign <file>                 writes <file>.sig; key from MINORDLNA_SIGNING_KEY or -key
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"flag"
	"fmt"
	"os"
	"strings"
)

func main() {
	keyFile := flag.String("key", "", "private key file (default: MINORDLNA_SIGNING_KEY env)")
	flag.Parse()
	args := flag.Args()
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: release keygen <private-key-file> | release [-key file] sign <file>")
		os.Exit(2)
	}
	var err error
	switch args[0] {
	case "keygen":
		err = keygen(args[1])
	case "sign":
		err = sign(*keyFile, args[1])
	default:
		err = fmt.Errorf("unknown command %q", args[0])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func keygen(path string) error {
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("%s already exists, refusing to overwrite", path)
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(base64.StdEncoding.EncodeToString(priv.Seed())+"\n"), 0o600); err != nil {
		return err
	}
	fmt.Println(base64.StdEncoding.EncodeToString(pub))
	return nil
}

func sign(keyFile, path string) error {
	enc := os.Getenv("MINORDLNA_SIGNING_KEY")
	if keyFile != "" {
		b, err := os.ReadFile(keyFile)
		if err != nil {
			return err
		}
		enc = string(b)
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(enc))
	if err != nil || len(seed) != ed25519.SeedSize {
		return fmt.Errorf("invalid or missing signing key")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	sig := ed25519.Sign(ed25519.NewKeyFromSeed(seed), data)
	return os.WriteFile(path+".sig", []byte(base64.StdEncoding.EncodeToString(sig)+"\n"), 0o644)
}
