// llmserve: makes the rock usable as a local OpenAI-compatible LLM endpoint.
//
// llama.cpp's own llama-server already speaks the OpenAI API (/v1/models,
// /v1/chat/completions incl. streaming), but it needs a single gguf -- and our
// weights ship as 4 raw chunks. Pebble's `after:` only orders service *starts*,
// so it cannot wait for the evaluator's reassembly, and a bare base has no
// shell to script "assemble && exec". Hence this wrapper: reassemble (shared,
// idempotent), then exec llama-server so it takes over the process pebble
// tracks.
package main

import (
	"log"
	"os"
	"strings"
	"syscall"

	"bonsai-rock/internal/model"
)

func main() {
	var (
		partDir   = env("BONSAI_MODEL_DIR", "/usr/share/bonsai")
		modelPath = env("BONSAI_MODEL", "/var/lib/bonsai/model.gguf")
		bin       = env("BONSAI_LLAMA_SERVER", "/usr/bin/llama-server")
		host      = env("BONSAI_LLM_HOST", "0.0.0.0")
		port      = env("BONSAI_LLM_PORT", "8082")
		ctxLen    = env("BONSAI_LLM_CTX", "8192")
		alias     = env("BONSAI_LLM_ALIAS", "bonsai-1.7b")
	)

	if err := model.Reassemble(partDir, modelPath); err != nil {
		log.Fatalf("model reassembly: %v", err)
	}

	// --alias sets the id reported by /v1/models, i.e. the model name a client
	// (opencode et al) is configured with.
	argv := []string{
		bin,
		"--model", modelPath,
		"--host", host,
		"--port", port,
		"--ctx-size", ctxLen,
		"--alias", alias,
	}
	// escape hatch for anything else llama-server takes (threads, batch, ...)
	if extra := strings.Fields(os.Getenv("BONSAI_LLM_ARGS")); len(extra) > 0 {
		argv = append(argv, extra...)
	}

	log.Printf("exec %s (port %s, ctx %s, alias %s)", bin, port, ctxLen, alias)
	if err := syscall.Exec(bin, argv, os.Environ()); err != nil {
		log.Fatalf("exec %s: %v", bin, err)
	}
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
