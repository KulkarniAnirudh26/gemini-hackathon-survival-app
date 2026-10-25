#!/bin/sh
# Downloads the models that are not already in $MODELS (default: ~/Personal/gemma-models/models).
set -eu
MODELS=${MODELS:-/c/Users/aniru/Personal/gemma-models/models}
B=https://huggingface.co
get() { # repo rev path dest
  if [ -s "$4" ]; then echo "have $4"; return; fi
  mkdir -p "$(dirname "$4")"
  echo "fetch $4"; curl -fL --retry 3 -C - -o "$4.part" "$B/$1/resolve/$2/$3" && mv "$4.part" "$4"
}
K=litert-community/kitten-tts-nano-0.8; KR=d4662d891f9bf54b3d93432610d0d296d229e026
M=litert-community/Matcha-TTS; MR=8d650e794583c0b0869c87027c2f3a7c293902cb
L=litert-community/Laya-Multilingual-LiteRT; LR=058cbf34ed2c6a2854ec60e9534c229d08740387
for f in kitten_predictor.tflite kitten_prosody.tflite kitten_vocoder.tflite voices.npz; do get $K $KR $f "$MODELS/kitten/$f"; done
for f in dp_g2p_matcha_fp16.tflite g2p_dict.txt.gz g2p_meta.json; do get $M $MR $f "$MODELS/kitten/$f"; done
for f in laya_ml_s256_embeds_wfp16.tflite laya_ml_act_head_fp32.tflite laya_ml_calibration.json tokenizer.json tokenizer_config.json token_embeddings_fp16.bin token_embeddings.json; do get $L $LR $f "$MODELS/laya_ml/$f"; done
echo done
