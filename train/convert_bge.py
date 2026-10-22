"""Converts BAAI/bge-small-zh-v1.5 to GGUF with the pinned llama.cpp converter.

The converter recognises tokenizers by a fingerprint list; bge-small-zh is missing from it, but it
uses the same Chinese WordPiece vocabulary as bge-large-zh-v1.5, which is listed ("bert-bge-large").
This wrapper answers that one question for this model and then runs the converter unchanged.

Run: PYTHONPATH=train/tools/src/gguf-py:train/tools/src train/.venv/bin/python train/convert_bge.py \
       train/models/bge-small-zh-v1.5 --outtype f16 --outfile train/models/gguf/bge-small-zh-f16.gguf
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "tools", "src")
sys.path[:0] = [SRC, os.path.join(SRC, "gguf-py")]

from conversion import base  # noqa: E402

original = base.TextModel.get_vocab_base_pre


def get_vocab_base_pre(self, tokenizer):
    if "bge-small-zh" in str(self.dir_model):
        return "bert-bge-large"
    return original(self, tokenizer)


base.TextModel.get_vocab_base_pre = get_vocab_base_pre

sys.argv[0] = os.path.join(SRC, "convert_hf_to_gguf.py")
import runpy  # noqa: E402

runpy.run_path(sys.argv[0], run_name="__main__")
