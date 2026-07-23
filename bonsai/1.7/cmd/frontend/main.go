// frontend: serves a tiny htmx chat client and proxies prompts to llama-server's
// OpenAI-compatible api. runs as a pebble service inside the rock; bind a host
// port to reach it.
package main

import (
	"bytes"
	"embed"
	"encoding/json"
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

//go:embed static
var static embed.FS

// fragment appended to the chat log on each turn: the user's line + the reply.
var frag = template.Must(template.New("f").Parse(
	`<div class="msg user">{{.User}}</div><div class="msg bot">{{.Bot}}</div>`))

func main() {
	addr := env("BONSAI_FRONTEND_ADDR", ":8080")
	llmURL := env("BONSAI_LLM_URL", "http://127.0.0.1:8082") + "/v1/chat/completions"
	cfg := chatConfig{
		model:     env("BONSAI_LLM_MODEL", "bonsai-1.7b"),
		maxTokens: envInt("BONSAI_MAX_TOKENS", 256),
		temp:      envFloat("BONSAI_TEMP", 0),
		system:    os.Getenv("BONSAI_SYSTEM"),
	}

	mux := http.NewServeMux()
	mux.Handle("/static/", http.FileServer(http.FS(static)))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		b, _ := static.ReadFile("static/index.html")
		w.Header().Set("content-type", "text/html; charset=utf-8")
		w.Write(b)
	})
	mux.HandleFunc("/send", func(w http.ResponseWriter, r *http.Request) {
		prompt := r.FormValue("prompt")
		if prompt == "" {
			http.Error(w, "empty prompt", http.StatusBadRequest)
			return
		}
		bot, err := complete(llmURL, cfg, prompt)
		if err != nil {
			log.Printf("llm error: %v", err)
			bot = "[error: " + err.Error() + "]"
		}
		w.Header().Set("content-type", "text/html; charset=utf-8")
		frag.Execute(w, struct{ User, Bot string }{prompt, bot})
	})

	log.Printf("frontend on %s -> llm %s", addr, llmURL)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

type chatConfig struct {
	model     string
	maxTokens int
	temp      float64
	system    string
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// complete posts one turn to the OpenAI-compatible endpoint and returns the
// assistant's reply. non-streaming: htmx swaps the whole fragment in at once.
func complete(url string, cfg chatConfig, prompt string) (string, error) {
	msgs := make([]chatMessage, 0, 2)
	if cfg.system != "" {
		msgs = append(msgs, chatMessage{Role: "system", Content: cfg.system})
	}
	msgs = append(msgs, chatMessage{Role: "user", Content: prompt})

	body, _ := json.Marshal(map[string]any{
		"model":       cfg.model,
		"max_tokens":  cfg.maxTokens,
		"temperature": cfg.temp,
		"messages":    msgs,
	})

	// generation is slow on cpu; give it room.
	cli := &http.Client{Timeout: 5 * time.Minute}
	resp, err := cli.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return "", &httpErr{resp.StatusCode, string(raw)}
	}

	var out struct {
		Choices []struct {
			Message chatMessage `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", err
	}
	if len(out.Choices) == 0 {
		return "", &httpErr{resp.StatusCode, "no choices in response"}
	}
	return stripThink(out.Choices[0].Message.Content), nil
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

type httpErr struct {
	code int
	body string
}

func (e *httpErr) Error() string { return e.body }

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
