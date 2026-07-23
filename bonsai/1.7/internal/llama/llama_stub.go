//go:build !cgo

// stub build so the evaluator's server logic compiles/vets without libllama
// present (CGO_ENABLED=0). real inference needs cgo + libllama.
package llama

import "errors"

// Load always fails off the linux+cgo path.
func Load(path string, ctxLen int) (Model, error) {
	return nil, errors.New("llama: real inference needs a linux build with cgo and libllama.so (this is the stub)")
}
