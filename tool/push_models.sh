#!/bin/sh
# Pushes the models from $MODELS to the app's external files dir on the connected phone.
# Run the app once first (or this creates the folder; the app reads it either way).
set -eu
MODELS=${MODELS:-/c/Users/aniru/Personal/gemma-models/models}
ADB=${ADB:-adb}
command -v "$ADB" >/dev/null 2>&1 || ADB="$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe"
D=/sdcard/Android/data/com.hackathon.yosemite_survival/files/models
"$ADB" shell mkdir -p $D/kitten $D/laya_ml
push() { echo "push $1 -> $2"; "$ADB" push "$1" "$2"; }
push "$MODELS/gemma-4-E2B-it.litertlm" $D/
push "$MODELS/Zipformer-medium-CR-CTC-LiteRT/zipformer_ctc_fp16.tflite" $D/
push "$MODELS/Zipformer-medium-CR-CTC-LiteRT/tokens.txt" $D/
for f in "$MODELS"/kitten/*; do push "$f" $D/kitten/; done
for f in "$MODELS"/laya_ml/*; do push "$f" $D/laya_ml/; done
"$ADB" shell ls -la $D $D/kitten $D/laya_ml
