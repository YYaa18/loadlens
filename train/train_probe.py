"""Trains the linear classifier ("probe") behind LoadLens's Jev-style decision model.

Input: vectors exported by `LoadLens --embed-export` into train/data/emb/<name>-<pooling>-<set>.jsonl
Output: train/models/probe-<name>-<pooling>.json, read by Sources/DecisionModel.swift

Model: softmax regression on standardised vectors, with L2 regularisation chosen on the
validation set. numpy only. Run:  train/.venv/bin/python train/train_probe.py qwen15 qwen2.5-1.5b-instruct-q4_k_m.gguf
"""
import json
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LABELS = ["user_files", "user_activity", "system", "dev_work", "script", "cache", "log", "app_data", "unknown"]
NOTIFY = {"script", "cache", "log", "app_data", "unknown"}


def load(name, pooling, split):
    path = os.path.join(ROOT, "train", "data", "emb", f"{name}-{pooling}-{split}.jsonl")
    rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
    x = np.array([r["embedding"] for r in rows], dtype=np.float64)
    y = np.array([LABELS.index(r["category"]) if "category" in r else -1 for r in rows])
    notify = np.array([r.get("expect_notify", r.get("category") in NOTIFY) for r in rows])
    return x, y, notify


def fit(x, y, l2, steps=400, lr=0.5):
    """Full-batch gradient descent on cross-entropy + L2. Small data, so this is plenty."""
    n, d = x.shape
    k = len(LABELS)
    w = np.zeros((k, d))
    b = np.zeros(k)
    onehot = np.eye(k)[y]
    for _ in range(steps):
        p = softmax(x @ w.T + b)
        grad = p - onehot
        w -= lr * (grad.T @ x / n + l2 * w)
        b -= lr * grad.mean(axis=0)
    return w, b


def softmax(z):
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


def report(tag, p, y, notify):
    pred = p.argmax(axis=1)
    pred_notify = np.array([LABELS[i] in NOTIFY for i in pred])
    labelled = y >= 0
    parts = [f"{tag}: 提醒判断 {np.mean(pred_notify == notify) * 100:.0f}%"]
    if labelled.any():
        parts.append(f"类别 {np.mean(pred[labelled] == y[labelled]) * 100:.0f}%")
    misses = int(np.sum(notify & ~pred_notify))
    alarms = int(np.sum(~notify & pred_notify))
    parts.append(f"漏报 {misses} 误报 {alarms}")
    print("  " + " · ".join(parts))


def main():
    # usage: train_probe.py <name> <model file> [--instruction TEXT] [--final]
    name, model_file = sys.argv[1], sys.argv[2]
    instruction = sys.argv[sys.argv.index("--instruction") + 1] if "--instruction" in sys.argv else None
    final = "--final" in sys.argv
    lowercase = "--lowercase" in sys.argv
    input_mode = "names" if "--names-only" in sys.argv else "description"
    poolings = sys.argv[sys.argv.index("--poolings") + 1].split(",") if "--poolings" in sys.argv else ["mean", "last"]
    best = None
    for pooling in poolings:
        xtr, ytr, _ = load(name, pooling, "train")
        xva, yva, _ = load(name, pooling, "valid")
        mean, scale = xtr.mean(axis=0), xtr.std(axis=0) + 1e-6
        ztr, zva = (xtr - mean) / scale, (xva - mean) / scale
        for l2 in (1e-4, 1e-3, 1e-2, 1e-1):
            w, b = fit(ztr, ytr, l2)
            acc = np.mean(softmax(zva @ w.T + b).argmax(axis=1) == yva)
            print(f"{pooling:4s} l2={l2:g}: 验证集类别 {acc * 100:.1f}%")
            if best is None or acc > best[0]:
                best = (acc, pooling, l2, mean, scale, w, b)

    acc, pooling, l2, mean, scale, w, b = best
    print(f"\n选用 {pooling} 池化，l2={l2:g}（验证集 {acc * 100:.1f}%）")
    # The test set is looked at once, at the very end (--final); choosing by it would be cheating.
    for split in ("train", "valid", "dev") + (("test",) if final else ()):
        x, y, notify = load(name, pooling, split)
        p = softmax(((x - mean) / scale) @ w.T + b)
        report(split, p, y, notify)

    probe = {"labels": LABELS, "pooling": pooling, "mean": mean.tolist(), "scale": scale.tolist(),
             "weights": w.tolist(), "bias": b.tolist(), "embeddingModel": model_file, "instruction": instruction, "lowercase": lowercase, "inputMode": input_mode}
    out = os.path.join(ROOT, "train", "models", f"probe-{name}-{pooling}.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(probe, f)
    print(f"\n→ {out}（{os.path.getsize(out) // 1024} KB）")


if __name__ == "__main__":
    main()
