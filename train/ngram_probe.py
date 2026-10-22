"""Smallest possible classifier: no neural network at all.

Features are hashed character n-grams (1-4 characters) of the names in the event (writer app and
process, or folder path and owner), fed to the same softmax regression as train_probe.py.
The whole model is a weight table, well under 1 MB. It can only recognise names that look like
names it has seen; the point is to measure how far that gets, with confidence telling us when to
ask a bigger model instead.

Run: train/.venv/bin/python train/ngram_probe.py
"""
import json
import os
import zlib

import numpy as np

from train_probe import LABELS, NOTIFY, fit, softmax

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIM = 1 << 14


def name_text(facts):
    if facts.get("path"):
        return f"{facts['path']} {facts.get('owner') or ''}"
    writers = facts.get("writers") or []
    return " ".join(f"{w['app']} {w['process']}" for w in writers[:1]) or "（无写入者）"


def featurize(text):
    v = np.zeros(DIM)
    t = f"^{text.lower()}$"
    for n in (1, 2, 3, 4):
        for i in range(len(t) - n + 1):
            v[zlib.crc32(t[i:i + n].encode("utf-8")) % DIM] += 1
    norm = np.linalg.norm(v)
    return v / norm if norm else v


def load_jsonl(name):
    rows = [json.loads(l) for l in open(os.path.join(ROOT, "train", "data", name), encoding="utf-8") if l.strip()]
    return rows


def load_exam(path):
    return json.load(open(os.path.join(ROOT, path), encoding="utf-8"))["cases"]


def matrix(rows):
    x = np.array([featurize(name_text(r["facts"])) for r in rows])
    y = np.array([LABELS.index(r["category"]) if r.get("category") else -1 for r in rows])
    notify = np.array([r.get("expect_notify", r.get("category") in NOTIFY) for r in rows])
    return x, y, notify


def coverage(p, y, notify):
    pred = p.argmax(1)
    conf = p.max(1)
    pred_notify = np.array([LABELS[i] in NOTIFY for i in pred])
    for t in (0.5, 0.7, 0.9):
        sure = conf >= t
        acc = np.mean(pred_notify[sure] == notify[sure]) * 100 if sure.any() else 0
        miss = int(np.sum(sure & notify & ~pred_notify))
        print(f"    置信度≥{t:.0%}: 本地决定 {sure.mean() * 100:.0f}%，其中提醒判断对 {acc:.0f}%，漏报 {miss}")


def main():
    xtr, ytr, _ = matrix(load_jsonl("facts-train.jsonl"))
    xva, yva, nva = matrix(load_jsonl("facts-valid.jsonl"))
    best = None
    for l2 in (1e-4, 1e-3, 1e-2):
        w, b = fit(xtr, ytr, l2, steps=600, lr=2.0)
        acc = np.mean(softmax(xva @ w.T + b).argmax(1) == yva)
        print(f"l2={l2:g}: 验证集类别 {acc * 100:.1f}%")
        if best is None or acc > best[0]:
            best = (acc, l2, w, b)
    acc, l2, w, b = best
    p = softmax(xva @ w.T + b)
    pred_notify = np.array([LABELS[i] in NOTIFY for i in p.argmax(1)])
    print(f"\n选用 l2={l2:g}：验证集类别 {acc * 100:.1f}% · 提醒判断 {np.mean(pred_notify == nva) * 100:.0f}%")
    coverage(p, yva, nva)
    size_kb = (w.size + b.size) * 2 // 1024  # stored as 16-bit floats
    print(f"模型大小约 {size_kb} KB（{len(LABELS)} 类 × {DIM} 维）")


if __name__ == "__main__":
    main()
