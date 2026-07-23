//go:build cgo

package llama

// include + lib search dirs come from CGO_CFLAGS / CGO_LDFLAGS set by the
// rockcraft "evaluator" part (pointing at the staged llama.cpp headers/libs),
// so nothing here is tied to a dev-machine layout.

/*
// mainline llama.cpp splits the cpu backend into libggml-cpu (it holds
// ggml_backend_cpu_reg, which libggml.so references) -- must link it too.
#cgo LDFLAGS: -lllama -lggml -lggml-cpu -lggml-base -lm -lstdc++
#include <stdlib.h>
#include <stdbool.h>
#include "llama.h"

// small C helpers to keep the cgo/go boundary simple.

// apply the model's built-in chat template to a system+user pair, writing the
// formatted prompt into buf. returns needed length (may exceed cap, per api).
static int bonsai_format(const struct llama_model * model, const char * sys,
                         const char * usr, char * buf, int cap) {
    struct llama_chat_message msgs[2];
    int n = 0;
    if (sys && sys[0]) { msgs[n].role = "system"; msgs[n].content = sys; n++; }
    msgs[n].role = "user"; msgs[n].content = usr; n++;
    const char * tmpl = llama_model_chat_template(model, NULL);
    return llama_chat_apply_template(tmpl, msgs, n, true, buf, cap);
}
*/
import "C"

import (
	"fmt"
	"strings"
	"sync"
	"unsafe"
)

type cgoModel struct {
	model *C.struct_llama_model
	vocab *C.struct_llama_vocab
	ctx   *C.struct_llama_context
	nCtx  int
	mu    sync.Mutex
}

var backendOnce sync.Once

// Load memory-maps the gguf at path and builds an inference context of ctxLen tokens.
func Load(path string, ctxLen int) (Model, error) {
	backendOnce.Do(func() { C.llama_backend_init() })

	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))

	mp := C.llama_model_default_params()
	// cpu only: leave n_gpu_layers at 0.
	model := C.llama_model_load_from_file(cpath, mp)
	if model == nil {
		return nil, fmt.Errorf("llama: failed to load model %q", path)
	}

	cp := C.llama_context_default_params()
	cp.n_ctx = C.uint(ctxLen)
	ctx := C.llama_init_from_model(model, cp)
	if ctx == nil {
		C.llama_model_free(model)
		return nil, fmt.Errorf("llama: failed to create context")
	}

	return &cgoModel{
		model: model,
		vocab: C.llama_model_get_vocab(model),
		ctx:   ctx,
		nCtx:  ctxLen,
	}, nil
}

func (m *cgoModel) Close() {
	if m.ctx != nil {
		C.llama_free(m.ctx)
		m.ctx = nil
	}
	if m.model != nil {
		C.llama_model_free(m.model)
		m.model = nil
	}
}

func (m *cgoModel) Complete(prompt string, opt Options) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if opt.MaxTokens <= 0 {
		opt.MaxTokens = 256
	}

	formatted, err := m.formatPrompt(opt.System, prompt)
	if err != nil {
		return "", err
	}
	tokens, err := m.tokenize(formatted, true)
	if err != nil {
		return "", err
	}
	if len(tokens) == 0 {
		return "", fmt.Errorf("llama: prompt tokenized to zero tokens")
	}
	if len(tokens) >= m.nCtx {
		return "", fmt.Errorf("llama: prompt (%d tok) exceeds context (%d)", len(tokens), m.nCtx)
	}

	smpl := m.newSampler(opt.Temp)
	defer C.llama_sampler_free(smpl)

	// decode the prompt in one batch.
	batch := C.llama_batch_get_one((*C.llama_token)(unsafe.Pointer(&tokens[0])), C.int32_t(len(tokens)))
	if C.llama_decode(m.ctx, batch) != 0 {
		return "", fmt.Errorf("llama: decode failed on prompt")
	}

	var sb strings.Builder
	nPast := len(tokens)
	for i := 0; i < opt.MaxTokens; i++ {
		tok := C.llama_sampler_sample(smpl, m.ctx, -1)
		if C.llama_vocab_is_eog(m.vocab, tok) {
			break
		}
		if nPast >= m.nCtx {
			break // context full
		}
		sb.WriteString(m.piece(tok))
		C.llama_sampler_accept(smpl, tok)

		one := C.llama_batch_get_one(&tok, 1)
		if C.llama_decode(m.ctx, one) != 0 {
			return sb.String(), fmt.Errorf("llama: decode failed at token %d", i)
		}
		nPast++
	}
	// reset kv cache so the next request starts clean.
	C.llama_memory_clear(C.llama_get_memory(m.ctx), C.bool(true))
	return strings.TrimSpace(sb.String()), nil
}

func (m *cgoModel) formatPrompt(system, user string) (string, error) {
	csys := C.CString(system)
	cusr := C.CString(user)
	defer C.free(unsafe.Pointer(csys))
	defer C.free(unsafe.Pointer(cusr))

	// first call with a generous buffer; grow if the api asks for more.
	cap := 4096
	for {
		buf := make([]byte, cap)
		n := int(C.bonsai_format(m.model, csys, cusr,
			(*C.char)(unsafe.Pointer(&buf[0])), C.int(cap)))
		if n < 0 {
			return "", fmt.Errorf("llama: chat template apply failed")
		}
		if n <= cap {
			return string(buf[:n]), nil
		}
		cap = n + 1
	}
}

func (m *cgoModel) tokenize(text string, addSpecial bool) ([]C.llama_token, error) {
	ctext := C.CString(text)
	defer C.free(unsafe.Pointer(ctext))
	n := len(text) + 8 // upper bound on token count
	toks := make([]C.llama_token, n)
	got := C.llama_tokenize(m.vocab, ctext, C.int32_t(len(text)),
		(*C.llama_token)(unsafe.Pointer(&toks[0])), C.int32_t(n),
		C.bool(addSpecial), C.bool(true))
	if got < 0 {
		return nil, fmt.Errorf("llama: tokenize overflow")
	}
	return toks[:got], nil
}

func (m *cgoModel) piece(tok C.llama_token) string {
	buf := make([]byte, 64)
	n := C.llama_token_to_piece(m.vocab, tok,
		(*C.char)(unsafe.Pointer(&buf[0])), C.int32_t(len(buf)), 0, C.bool(true))
	if n < 0 {
		buf = make([]byte, -n)
		n = C.llama_token_to_piece(m.vocab, tok,
			(*C.char)(unsafe.Pointer(&buf[0])), C.int32_t(len(buf)), 0, C.bool(true))
	}
	if n <= 0 {
		return ""
	}
	return string(buf[:n])
}

// newSampler builds a greedy chain (temp<=0) or a temp+dist chain.
func (m *cgoModel) newSampler(temp float32) *C.struct_llama_sampler {
	sp := C.llama_sampler_chain_default_params()
	chain := C.llama_sampler_chain_init(sp)
	if temp <= 0 {
		C.llama_sampler_chain_add(chain, C.llama_sampler_init_greedy())
	} else {
		C.llama_sampler_chain_add(chain, C.llama_sampler_init_temp(C.float(temp)))
		C.llama_sampler_chain_add(chain, C.llama_sampler_init_dist(C.LLAMA_DEFAULT_SEED))
	}
	return chain
}
