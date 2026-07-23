// Package model handles turning the shipped model chunks back into a gguf.
//
// the weights ride in as 4 separate oci layers at <dir>/*.part[0-3] -- raw byte
// slices of the original file, not gguf-split shards -- so they must be
// concatenated before llama.cpp can load them. both the evaluator and the
// llama-server wrapper call Reassemble on startup.
package model

import (
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
)

// Reassemble concatenates <dir>/*.part* into dst in lexical order. It is a
// no-op if dst already exists and is non-empty (the writable layer caches it
// across restarts).
//
// Safe to run from two processes at once: each writes its own uniquely-named
// temp file and renames it into place atomically, so the worst case is a
// duplicated write on first boot, never a torn file.
func Reassemble(dir, dst string) error {
	if fi, err := os.Stat(dst); err == nil && fi.Size() > 0 {
		log.Printf("model already assembled at %s (%d bytes)", dst, fi.Size())
		return nil
	}
	parts, err := filepath.Glob(filepath.Join(dir, "*.part*"))
	if err != nil {
		return err
	}
	if len(parts) == 0 {
		return errors.New("no model parts found in " + dir)
	}
	sort.Strings(parts)
	log.Printf("assembling %d parts -> %s", len(parts), dst)

	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	// unique temp + rename: a crash mid-write never leaves a partial file that
	// the size check above would wrongly accept, and concurrent writers cannot
	// clobber each other's temp.
	out, err := os.CreateTemp(filepath.Dir(dst), filepath.Base(dst)+".tmp")
	if err != nil {
		return err
	}
	tmp := out.Name()
	defer os.Remove(tmp) // no-op once the rename below succeeds

	for _, p := range parts {
		in, err := os.Open(p)
		if err != nil {
			out.Close()
			return err
		}
		if _, err := io.Copy(out, in); err != nil {
			in.Close()
			out.Close()
			return err
		}
		in.Close()
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}
