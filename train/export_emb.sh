#!/bin/bash
# Exports vectors for every set with one model:
#   train/export_emb.sh <model.gguf> <name> [instruction] [poolings, default "mean last"] [extra flags, e.g. --lowercase]
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL="$1"; NAME="$2"; INSTRUCTION="${3:-}"; POOLINGS="${4:-mean last}"; EXTRA="${5:-}"
B=build/LoadLens.app/Contents/MacOS/LoadLens
mkdir -p train/data/emb
for POOL in $POOLINGS; do
    for SET in train valid; do
        "$B" --embed-export "$MODEL" "train/data/facts-$SET.jsonl" "train/data/emb/$NAME-$POOL-$SET.jsonl" --pooling $POOL --instruction "$INSTRUCTION" $EXTRA
    done
    "$B" --embed-export "$MODEL" eval/triage-test.json "train/data/emb/$NAME-$POOL-test.jsonl" --pooling $POOL --instruction "$INSTRUCTION" $EXTRA
    "$B" --embed-export "$MODEL" eval/triage-cases.json "train/data/emb/$NAME-$POOL-dev.jsonl" --pooling $POOL --instruction "$INSTRUCTION" $EXTRA
done
