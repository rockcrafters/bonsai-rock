// frontend: serves a tiny htmx chat client and proxies prompts to the evaluator
// service. runs as a pebble service inside the rock; bind a host port to reach it.
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
	"time"
)

//go:embed static
var static embed.FS

// fragment appended to the chat log on each turn: the user's line + the reply.
var frag = template.Must(template.New("f").Parse(
	`<div class="msg user">{{.User}}</div><div class="msg bot">{{.Bot}}</div>`))

func main() {
	addr := env("BONSAI_FRONTEND_ADDR", ":8080")
	evalURL := env("BONSAI_EVAL_URL", "http://127.0.0.1:8081") + "/complete"

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
		bot, err := complete(evalURL, prompt)
		if err != nil {
			log.Printf("eval error: %v", err)
			bot = "[error: " + err.Error() + "]"
		}
		w.Header().Set("content-type", "text/html; charset=utf-8")
		frag.Execute(w, struct{ User, Bot string }{prompt, bot})
	})

	log.Printf("frontend on %s -> evaluator %s", addr, evalURL)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

// complete posts the prompt to the evaluator and returns its text reply.
func complete(url, prompt string) (string, error) {
	body, _ := json.Marshal(map[string]any{"prompt": prompt})
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
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", err
	}
	return out.Text, nil
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
