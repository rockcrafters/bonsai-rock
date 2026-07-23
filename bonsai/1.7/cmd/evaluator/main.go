// evaluator: loads the bonsai gguf and serves single-turn completions over http.
// runs as a pebble service; the frontend talks to it on localhost.
//
// the model ships split across 4 oci layers as <dir>/*.part[0-3]; on startup we
// reassemble them into one gguf (skipped if the assembled file already exists),
// then mmap-load it via llama.cpp.
package main

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"bonsai-rock/internal/llama"
)

func main() {
	var (
		addr      = env("BONSAI_EVAL_ADDR", ":8081")
		partDir   = env("BONSAI_MODEL_DIR", "/usr/share/bonsai")
		modelPath = env("BONSAI_MODEL", "/var/lib/bonsai/model.gguf")
		ctxLen    = envInt("BONSAI_CTX", 1024)
		maxTok    = envInt("BONSAI_MAX_TOKENS", 256)
		temp      = float32(envFloat("BONSAI_TEMP", 0.0))
		system    = os.Getenv("BONSAI_SYSTEM")
	)

	if err := reassemble(partDir, modelPath); err != nil {
		log.Fatalf("model reassembly: %v", err)
	}

	log.Printf("loading %s (ctx=%d)...", modelPath, ctxLen)
	model, err := llama.Load(modelPath, ctxLen)
	if err != nil {
		log.Fatalf("load: %v", err)
	}
	defer model.Close()
	log.Printf("model ready")

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("/complete", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "post only", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Prompt string `json:"prompt"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Prompt == "" {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		text, err := model.Complete(req.Prompt, llama.Options{
			MaxTokens: maxTok,
			Temp:      temp,
			System:    system,
		})
		text = stripThink(text)
		if err != nil {
			log.Printf("complete: %v", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("content-type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"text": text})
	})

	log.Printf("evaluator on %s", addr)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

// reassemble concatenates <dir>/*.part* into dst in lexical order. no-op if dst
// already exists (writable-layer cache across restarts).
func reassemble(dir, dst string) error {
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
	// write to a temp then rename, so a crash mid-write never leaves a partial
	// file that the size check above would wrongly accept.
	tmp := dst + ".tmp"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
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

// stripThink removes a leading qwen3 <think>...</think> reasoning block, which
// bonsai emits (often empty) and which we don't surface in the chat ui.
func stripThink(s string) string {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "<think>") {
		if i := strings.Index(s, "</think>"); i >= 0 {
			s = s[i+len("</think>"):]
		}
	}
	return strings.TrimSpace(s)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envFloat(k string, def float64) float64 {
	if v := os.Getenv(k); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}
