# Pixel 10 Pro benchmark data

Measured November 15, 2026 on a Pixel 10 Pro.

## Gemma generation

[AI Edge Gallery configuration averages](gemma-ai-edge-gallery.csv) records the reported averages from AI Edge Gallery 1.0.23. Each configuration ran three times with 256 prefill tokens and 256 decode tokens. Timestamps are in local time. A blank steady initialization cell means the benchmark did not report it.

## Sherpa voice pipeline

[LiteRT samples](litert-raw-results.jsonl) contains Laya and KittenTTS initialization and latency samples. [Zipformer samples](zipformer-raw-results.jsonl) contains the successful Zipformer-only run. The combined LiteRT log retains the unsuccessful Zipformer attempt with an empty fixture for provenance. Published Zipformer results use the dedicated successful run.

Sherpa’s component harness used LiteRT 2.3.0 and ran three warmups followed by 20 timed calls per component. Each JSONL sample has a `warmup` flag. The tables use the arithmetic mean and linearly interpolated 95th percentile of the timed calls. Each initialization value in the logs is a single model-open observation.

- **Laya Multilingual, GPU.** One timed call evaluates the four first-pass classifier questions against “Where is the nearest water?” and includes tokenization and result serialization. The optional topic pass and the final routing decision are outside that timing.
- **Zipformer CTC, GPU.** Transcribes a 4.5555 s, 16 kHz mono, synthetic speech fixture in memory. The fixture says “They tap Get Me Out. Sherpa searches the offline trail graph from the current position.”
- **KittenTTS Nano 0.8, CPU.** Synthesizes “The nearest water is at the river crossing. Follow the trail to the marked junction, then continue east for two hundred meters.” with `expr-voice-2-m` at the default rate. The generated audio is 8.4167 s. The timing covers synthesis in memory.

Real-time factor is processing time divided by audio duration. In the recognition run it uses input duration. In the synthesis run it uses output duration.

## Kitten ASR comparison

[Kitten ASR samples](kitten-asr-raw-results.jsonl) uses the same fixture as Zipformer. The community INT8 model ran on CPU with four ONNX Runtime 1.25.0 threads, using the same warmup and sample counts. These are single-clip timings. [Community INT8 model](https://huggingface.co/zhaoyang-jia/kitten-asr-tiny-onnx-int8) · [Runner revision](https://github.com/itamaker/kitten-asr-go/tree/84080676f3d03cc77a1bb633efd559936f07c3b5).

[Model file SHA-256 hashes](model-sha256.txt) identify the benchmark assets. The speech fixture SHA-256 is `dc3d8132df22eff82d038f0ec8779cf40fb81764a8d019e3500263ed5d531b74`.
