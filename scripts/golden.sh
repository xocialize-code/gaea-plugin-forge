#!/bin/zsh
# Every model the pack serves, called over GPP on the signed bundle (gaea-plugin-check: launch under the launch
# requirement, configure, prepare, run, shutdown) and compared with ForgeCore's in-process output for the same call
# (forge-inproc: ForgeEngineService, registered as ForgeCore registers it, on this package's dependency resolution):
# byte for byte, and pixel for pixel when the bytes differ.
#
#   scripts/golden.sh <out-dir>          (after scripts/build-plugin.sh and `swift build -c release --product forge-inproc`)
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/forge.gaeaplugin
MODELS=${CHECK_MODELS_ROOT:-$HOME/Library/Application Support/MLXEngine/Models}
BIN=$(xcrun swift build -c release --show-bin-path)
CHECK=$BIN/gaea-plugin-check; INPROC=$BIN/forge-inproc
FOX=$ROOT/scripts/fixtures/fox-256.png; MASK=$ROOT/scripts/fixtures/mask-256.png; FACE=$ROOT/scripts/fixtures/face-512.png
PIXDIFF=$OUT/pixdiff; swiftc -O -o $PIXDIFF $ROOT/scripts/pixdiff.swift
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }

# name, plugin model, lane, MES operation, GPP params, ForgeModel, forge-inproc options…
golden() {
  local name=$1 model=$2 lane=$3 op=$4 params=$5 forge=$6; shift 6
  # The face models get a portrait: on a picture without a face they hand it back unchanged, which proves nothing.
  local img=$FOX; [[ $model == *-face ]] && img=$FACE
  local inputs=(--input "image=$img"); [[ $op == image.fill ]] && inputs+=(--input "mask=$MASK")
  $CHECK $B --operation $op --model $model --lane $lane --params $params $inputs --models-root "$MODELS" --budget 64000000000 \
    --timeout 300 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(grep -o '"path":"[^"]*"' $OUT/$name-gpp.log | head -1 | sed 's/"path":"//; s/"$//; s/\\\//\//g')
  local ran=$(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1)
  local foot=$(grep -o 'host read [0-9]* B' $OUT/$name-gpp.log | head -1)
  [[ -n $file && -f $file ]] && cp $file $OUT/$name-gpp.png
  $INPROC --model $forge --image $img "$@" --models-root "$MODELS" --out $OUT/$name-inproc.png > $OUT/$name-inproc.json 2>> $LOG
  if [[ ! -f $OUT/$name-gpp.png ]]; then fail=$((fail+1)); say "FAIL  $name: no output over GPP ($(tail -1 $OUT/$name-gpp.log))"; return; fi
  if [[ ! -f $OUT/$name-inproc.png ]]; then fail=$((fail+1)); say "FAIL  $name: no in-process output"; return; fi
  local a=$(shasum -a 256 $OUT/$name-gpp.png | cut -c1-16) b=$(shasum -a 256 $OUT/$name-inproc.png | cut -c1-16)
  if [[ $a == $b ]]; then
    pass=$((pass+1)); say "PASS  $name ($model $lane, $op): byte-identical, sha256 $a…; over GPP $ran, $foot; in-process $(cat $OUT/$name-inproc.json)"
  elif $PIXDIFF $OUT/$name-gpp.png $OUT/$name-inproc.png >> $LOG 2>&1; then
    pass=$((pass+1)); say "PASS  $name ($model $lane, $op): pixel-identical (bytes $a… / $b…); over GPP $ran, $foot"
  else
    fail=$((fail+1)); say "FAIL  $name ($model $lane, $op): differs ($a… / $b…): $(tail -1 $LOG)"
  fi
}

say "# Forge pack golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
golden lama lama-inpaint fp16 image.fill '{}' inpaint --mask $MASK
golden migan lama-inpaint fp16 image.fill '{"mode":"fast"}' inpaint --mask $MASK --mode fast
golden nerve nerve-upscale fp16 image.upscale '{"scale":2}' upscale --scale 2
golden edgetam edgetam-segment fp16 image.segment '{"points":[[150,120]],"pointLabels":[1]}' promptMask --points 150,120 --labels 1
golden realplksr realplksr-upscale fp32 image.upscale '{"scale":4}' upscaleFidelity --scale 4
golden heart heart-upscale fp16 image.upscale '{"scale":4}' upscaleHEART --scale 4
golden birefnet birefnet-matte fp16 image.matte '{"kind":"softAlpha"}' matte --kind softAlpha
golden sam21 sam21-segment fp16 image.segment '{"points":[[150,120]],"pointLabels":[1]}' promptMaskQuality --points 150,120 --labels 1
golden nafnet nafnet-restore fp16 image.restore '{}' restore
golden restormer-motion restormer-motion fp32 image.restore '{}' restormerMotion
golden restormer-defocus restormer-defocus fp32 image.restore '{}' restormerDefocus
golden restormer-denoise restormer-denoise fp32 image.restore '{}' restormerDenoise
golden scunet scunet-denoise fp32 image.restore '{}' denoiseBlind
golden gfpgan gfpgan-face fp32 image.restore '{}' faceRestore
golden restoreformer restoreformer-face fp32 image.restore '{}' faceRestoreVQ
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
