// package llama is a minimal cgo wrapper over llama.cpp's C API, enough to load
// a gguf and run a single chat completion on cpu. it deliberately covers only
// what the evaluator needs; it is not a general binding.
package llama

// Options configure a completion.
type Options struct {
	MaxTokens int
	Temp      float32
	System    string
}

// Model is a loaded gguf + inference context. not safe for concurrent Complete.
type Model interface {
	// Complete runs one system+user turn and returns the assistant text.
	Complete(prompt string, opt Options) (string, error)
	Close()
}
