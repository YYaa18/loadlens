# 第三方组件 / Third-party components

## bge-small-zh-v1.5（本地分诊用的嵌入模型）

- 来源：BAAI（北京智源人工智能研究院），https://modelscope.cn/models/BAAI/bge-small-zh-v1.5
- 许可证：MIT License
- 本目录中的 `bge-small-zh-q8_0.gguf` 由原始权重经 llama.cpp b11413 转换并量化为 8 位（见 `train/convert_bge.py`），
  SHA256 `fff62e0eac258740543ee045fab690307e194eb8bbc19b873d2a0167bacc3182`。
- `probe.json` 是在它的向量上训练的分类器（见 `train/train_probe.py`），只适用于这一个模型文件。

## llama.cpp（随应用打包的推理引擎）

- 来源：https://github.com/ggml-org/llama.cpp（预编译框架，版本 b11413）
- 许可证：MIT License，Copyright (c) 2023-2026 The ggml authors

## MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
