#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "llama-cpp-python",
#     "huggingface-hub",
#     "numpy",
# ]
# ///
# based on https://www.nobodywho.ai/posts/jev-in-25-lines/
import argparse
import os
import string
from pathlib import Path
import numpy
from huggingface_hub import hf_hub_download
from llama_cpp import Llama

parser = argparse.ArgumentParser(description="classify with bonsai 1.7b logits, jev style")
parser.add_argument("prompt", help="text to classify")
parser.add_argument("-c", "--choice", action="append", dest="choices", help="choice (repeatable)")
args = parser.parse_args()
choices = args.choices or ["Legitimate", "Spam", "Phishing"]
labels = list(string.ascii_uppercase[: len(choices)])
if len(choices) == 1:
    print(f"{1.0:.3f}  {choices[0]}")
    raise SystemExit

model_path = hf_hub_download(
    repo_id="prism-ml/Bonsai-1.7B-gguf",
    filename="Bonsai-1.7B-Q1_0.gguf",
    local_dir=Path(os.environ.get("HF_HOME", "~/.cache/huggingface")).expanduser() / "bonsai",
)
llm = Llama(model_path=model_path, n_ctx=1024, n_gpu_layers=-1, logits_all=True, verbose=False)

options = "\n".join(f"{label}. {choice}" for label, choice in zip(labels, choices, strict=True))
prompt = f"""<|im_start|>system
Reply with only the letter of the best option.<|im_end|>
<|im_start|>user
{args.prompt}\n\n{options}<|im_end|>
<|im_start|>assistant
<think>\n\n</think>\n\n"""
llm.eval(tokens=llm.tokenize(text=prompt.encode(), add_bos=False, special=True))

logits = llm.scores[llm.n_tokens - 1]
token_ids = [llm.tokenize(text=label.encode(), add_bos=False)[0] for label in labels]
choice_logits = numpy.asarray([logits[token_id] for token_id in token_ids])
probabilities = numpy.exp(choice_logits - numpy.logaddexp.reduce(choice_logits))
for choice, p in sorted(zip(choices, probabilities, strict=True), key=lambda x: -x[1]):
    print(f"{p:.3f}  {choice}")
