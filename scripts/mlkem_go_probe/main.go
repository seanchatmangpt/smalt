// BK-2 IMPL-14 ML-KEM Go leg: raw ML-KEM-768 interop probe against
// smalt's OTP 29 crypto:mlkem768 surface. Real files, no mocks.
//
// Wire format (raw FIPS 203 byte strings, no envelopes):
//   ek = 1184 bytes, ct = 1088 bytes, ss = 32 bytes — the interop surface;
//   these are byte-identical on both sides (identity conversion).
// Private keys differ by serialization: Go crypto/mlkem serializes
// DecapsulationKey768.Bytes() as the 64-byte "d||z" seed; OTP 29
// crypto:generate_key(mlkem768, []) yields the raw 2400-byte expanded dk.
// Each side parses only its own private form; no private key crosses the
// boundary in this probe.
package main

import (
	"bytes"
	"crypto/mlkem"
	"errors"
	"fmt"
	"os"
)

func die(err error) {
	fmt.Fprintln(os.Stderr, "ERR:", err)
	os.Exit(1)
}

func readExact(path string, want int) []byte {
	b, err := os.ReadFile(path)
	if err != nil {
		die(err)
	}
	if len(b) != want {
		die(fmt.Errorf("%s: got %d bytes, want %d (raw FIPS 203 byte string)", path, len(b), want))
	}
	return b
}

func write(file string, b []byte) {
	if err := os.WriteFile(file, b, 0o600); err != nil {
		die(err)
	}
	fmt.Printf("WROTE %s %d bytes\n", file, len(b))
}

func main() {
	if len(os.Args) < 2 {
		die(errors.New("usage: golegprobe keygen <ek-out> <seed-out> | encap <ek-file> <ct-out> <ss-out> | decap <seed-file> <ct-file> <ss-out> | corrupt-decap <seed-file> <ct-file> <valid-ss-file>"))
	}
	switch os.Args[1] {
	case "keygen":
		dkObj, err := mlkem.GenerateKey768()
		if err != nil {
			die(err)
		}
		write(os.Args[2], dkObj.EncapsulationKey().Bytes()) // 1184
		write(os.Args[3], dkObj.Bytes())                    // 64 (d||z seed)
	case "encap":
		ek := readExact(os.Args[2], 1184)
		ekObj, err := mlkem.NewEncapsulationKey768(ek)
		if err != nil {
			die(fmt.Errorf("parse ek: %w", err))
		}
		ss, ct := ekObj.Encapsulate()
		write(os.Args[3], ct)   // 1088
		write(os.Args[4], ss)   // 32
	case "decap":
		seed := readExact(os.Args[2], 64)
		dkObj, err := mlkem.NewDecapsulationKey768(seed)
		if err != nil {
			die(fmt.Errorf("parse seed: %w", err))
		}
		ct := readExact(os.Args[3], 1088)
		ss, err := dkObj.Decapsulate(ct)
		if err != nil {
			die(err)
		}
		write(os.Args[4], ss)
	case "corrupt-decap":
		seed := readExact(os.Args[2], 64)
		dkObj, err := mlkem.NewDecapsulationKey768(seed)
		if err != nil {
			die(fmt.Errorf("parse seed: %w", err))
		}
		ct := readExact(os.Args[3], 1088)
		ss, err := dkObj.Decapsulate(ct)
		if err != nil {
			fmt.Printf("GO-CORRUPT-CT typed_refusal=%v\n", err)
			return
		}
		valid, err := os.ReadFile(os.Args[4])
		if err != nil {
			die(err)
		}
		if bytes.Equal(ss, valid) {
			die(errors.New("corrupted ct decapsulated to the VALID shared secret — interop falsified"))
		}
		fmt.Printf("GO-CORRUPT-CT ss_differs_from_valid=%v ss_len=%d (no crash)\n", !bytes.Equal(ss, valid), len(ss))
	default:
		die(fmt.Errorf("unknown command %q", os.Args[1]))
	}
}
