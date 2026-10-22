#!/bin/bash
# LoRA fine-tune of Qwen2.5-1.5B-Instruct for disk-event triage (category classification).
# Inputs: train/data/{train,valid}.jsonl (from make_data.py + LoadLens --triage-export).
set -euo pipefail
cd "$(dirname "$0")/.."

# 1440 examples / batch 4 = 360 steps per pass over the data; 720 steps = 2 passes.
# --mask-prompt: learn only from the answer, not from repeating the (fixed) system prompt.
# --num-layers 16: attach LoRA to the top 16 of 28 layers.
train/.venv/bin/python -m mlx_lm lora \
    --model train/models/Qwen2.5-1.5B-Instruct \
    --train \
    --data train/data \
    --fine-tune-type lora \
    --num-layers 16 \
    --batch-size 4 \
    --iters 720 \
    --learning-rate 1e-4 \
    --mask-prompt \
    --max-seq-length 1024 \
    --steps-per-eval 90 \
    --val-batches 60 \
    --save-every 180 \
    --adapter-path train/models/adapters-v3 \
    --seed 1
