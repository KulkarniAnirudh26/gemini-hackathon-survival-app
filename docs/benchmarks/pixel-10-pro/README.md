# Pixel 10 Pro benchmark data

Measured November 15, 2026 on a Pixel 10 Pro.

## Gemma generation

| Metric / parameter | Gemini Nano via AICore · TPU | Gemma 4 E2B-it via LiteRT-LM · CPU | Gemma 4 E2B-it via LiteRT-LM · TPU |
| --- | ---: | ---: | ---: |
| Timestamp (local) | 2026-11-15 14:00:39 | 2026-11-15 14:02:58 | 2026-11-15 14:04:31 |
| AI Edge Gallery version | 1.0.23 | 1.0.23 | 1.0.23 |
| Prefill tokens | 256 | 256 | 256 |
| Decode tokens | 256 | 256 | 256 |
| Runs | 3 | 3 | 3 |
| Mean prefill speed (tokens/s) | 616.14 | 229.87 | 1904.54 |
| Mean decode speed (tokens/s) | 47.17 | 15.74 | 19.49 |
| Mean time to first token (s) | 0.45 | 1.18 | 0.19 |
| Mean first initialization (ms) | 107.57 | 8438.25 | 7798.01 |
| Mean steady initialization (ms) | — | 791.29 | 2440.95 |

A dash means AI Edge Gallery did not report that value.

## Sherpa voice pipeline

| Model | Backend | Mean (ms) | Median (ms) | p95 (ms) | Initialization (ms) | Real-time factor |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Zipformer CTC | LiteRT GPU | 224.53 | 226.04 | 240.24 | 1,355.08 | 0.049× |
| Laya Multilingual | LiteRT GPU | 1,094.67 | 1,109.57 | 1,129.47 | 3,885.01 | — |
| KittenTTS Nano 0.8 | LiteRT CPU | 798.19 | 799.64 | 810.78 | 626.89 | 0.095× |

[LiteRT samples](litert-raw-results.jsonl) contains Laya and KittenTTS initialization and latency samples. [Zipformer samples](zipformer-raw-results.jsonl) contains the successful Zipformer-only run. The combined LiteRT log retains the unsuccessful Zipformer attempt with an empty fixture for provenance. Published Zipformer results use the dedicated successful run.

Sherpa’s component harness used LiteRT 2.3.0 and ran three warmups followed by 20 timed calls per component. Each JSONL sample has a `warmup` flag. The tables use the arithmetic mean and linearly interpolated 95th percentile of the timed calls. Each initialization value in the logs is a single model-open observation.

- **Laya Multilingual, GPU.** One timed call evaluates the four first-pass classifier questions against “Where is the nearest water?” and includes tokenization and result serialization. The optional topic pass and the final routing decision are outside that timing.
- **Zipformer CTC, GPU.** Transcribes a 4.5555 s, 16 kHz mono, synthetic speech fixture in memory. The fixture says “They tap Get Me Out. Sherpa searches the offline trail graph from the current position.”
- **KittenTTS Nano 0.8, CPU.** Synthesizes “The nearest water is at the river crossing. Follow the trail to the marked junction, then continue east for two hundred meters.” with `expr-voice-2-m` at the default rate. The generated audio is 8.4167 s. The timing covers synthesis in memory.

Real-time factor is processing time divided by audio duration. In the recognition run it uses input duration. In the synthesis run it uses output duration.

## Kitten ASR comparison

| Model | Backend | Mean (ms) | Median (ms) | p95 (ms) | Initialization (ms) | Real-time factor |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Kitten ASR Tiny INT8 | ONNX Runtime CPU, 4 threads | 5,795.76 | 5,909.05 | 6,901.26 | 4,359.88 | 1.272× |

[Kitten ASR samples](kitten-asr-raw-results.jsonl) uses the same fixture as Zipformer. The community INT8 model ran on CPU with four ONNX Runtime 1.25.0 threads, using the same warmup and sample counts. These are single-clip timings. [Community INT8 model](https://huggingface.co/zhaoyang-jia/kitten-asr-tiny-onnx-int8) · [Runner revision](https://github.com/itamaker/kitten-asr-go/tree/84080676f3d03cc77a1bb633efd559936f07c3b5).

[Model file SHA-256 hashes](model-sha256.txt) identify the benchmark assets. The speech fixture SHA-256 is `dc3d8132df22eff82d038f0ec8779cf40fb81764a8d019e3500263ed5d531b74`.
