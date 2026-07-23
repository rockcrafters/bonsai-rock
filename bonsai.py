#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "llama-cpp-python",
#     "huggingface-hub",
#     #
# ]
# ///
import argparse
import os
from pathlib import Path
from huggingface_hub import hf_hub_download
from llama_cpp import Llama

parser = argparse.ArgumentParser(description="run bonsai 1.7b locally")
parser.add_argument("prompt", help="prompt to send")
parser.add_argument("--system", default="", help="system instruction for model")
parser.add_argument("--temp", type=float, default=0.0)
args = parser.parse_args()

model_path = hf_hub_download(
    repo_id="prism-ml/Bonsai-1.7B-gguf",
    filename="Bonsai-1.7B-Q1_0.gguf",
    local_dir=Path(os.environ.get("HF_HOME", "~/.cache/huggingface")).expanduser() / "bonsai",
)
llm = Llama(model_path=model_path, n_ctx=1024, n_gpu_layers=-1, verbose=False)

result = llm.create_chat_completion(
    messages=[
        {"role": "system", "content": args.system},
        {"role": "user", "content": args.prompt},
    ],
    max_tokens=256,
    temperature=args.temp,
    stream=True,
)
for chunk in result:
    print(chunk["choices"][0]["delta"].get("content", ""), end="", flush=True)
print()