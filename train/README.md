# 本地分诊模型的训练与评测

硬盘事件超过提醒门槛之后，判断"值不值得打扰用户"。决策分五层（`Sources/HybridTriage.swift`）：

```
硬规则（空间快满） → 本地记忆 → 本地小模型（置信度 ≥ 70%） → 云端模型 → 兜底提醒
```

本地小模型 = 嵌入模型（bge-small-zh-v1.5，8 位 GGUF，25MB）+ 线性分类器（Jev 式：固定的 9 个类别，带置信度）。
类别是否提醒由代码决定（`Triage.Category.notify`），改规则不用重新训练。

## 数据

| 文件 | 内容 |
|---|---|
| `make_data.py` | 生成训练集 / 验证集 / 测试集 v1、v2。名字池互不重叠，脚本里有检查 |
| `../eval/triage-cases.json` | 模拟考 22 道，答案由用户审定 |
| `../eval/triage-test.json` | 测试集 v1（60 道），已冻结 |
| `../eval/triage-test-v2.json` | 测试集 v2（90 道），第三轮补数据之后才生成，用作最终裁判 |

规矩：方案只按验证集挑；测试集只在最后看一次。验证集的名字必须是训练里没见过的。

## 环境（全部装在 `train/` 下，已在 `.gitignore`）

```bash
/usr/bin/python3 -m venv train/.venv
train/.venv/bin/pip install -r train/requirements.txt torch==2.8.0
```

llama.cpp 转换工具和量化工具用与应用相同的锁定版本 b11413，放在 `train/tools/`（源码包 + `llama-b11413-bin-macos-arm64.tar.gz`）。
模型权重放在 `train/models/`（从 ModelScope 下载并核对 SHA256）。

## 流程

```bash
python3 train/make_data.py                                   # 1. 生成事实数据
B=build/LoadLens.app/Contents/MacOS/LoadLens

# 2a. 嵌入 + 分类器（当前方案）
train/.venv/bin/python train/convert_bge.py train/models/bge-small-zh-v1.5 --outtype q8_0 \
    --outfile train/models/gguf/bge-small-zh-q8_0.gguf
./train/export_emb.sh train/models/gguf/bge-small-zh-q8_0.gguf bge8names "" "cls mean" "--lowercase --names-only"
train/.venv/bin/python train/train_probe.py bge8names bge-small-zh-q8_0.gguf --poolings cls,mean --lowercase --names-only

# 2b. LoRA 微调 Qwen2.5-1.5B（对照组，940MB）
$B --triage-export train/data/facts-train.jsonl train/data/train.jsonl
$B --triage-export train/data/facts-valid.jsonl train/data/valid.jsonl
./train/train.sh

# 3. 评测
$B --probe-eval <模型.gguf> <分类器.json> <考题.json>     # 本地模型 + 置信度门槛
$B --hybrid-eval <模型.gguf> <分类器.json> <考题.json>    # 五层决策，模拟云端，不联网
$B --cloud-eval <考题.json>                               # 真实云端（会把考题发给已配置的模型服务）
```

注意：bge-small-zh 的词表没有大写字母（"Docker" 会变成 [UNK]），必须先转小写；`--lowercase` 会写进分类器文件，应用里自动照做。

## 第三轮结论（验证集，名字均未在训练中出现）

| 方案 | 大小 | 耗时 | 置信度 ≥70% 本地决定 | 其中提醒判断准确率 |
|---|---|---|---|---|
| 字符片段分类器 | 288KB | <1ms | 28% | 94% |
| bge-small + 分类器 | 25MB | 8ms | 36% | 100% |
| Qwen 1.5B LoRA + 分类器 | 940MB | 47ms | 76% | 98% |
| 云端 DeepSeek（deepseek-flash） | — | 中位数 1.4s | — | 91%（类别 75%） |
