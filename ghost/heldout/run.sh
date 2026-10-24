#!/bin/sh
# Fits Ghost Mode's predictors on training walks and scores them, with the learned movement
# model, on held-out Hervanta walks. Offline; writes ghost/results/.
#
#   ML_DIR=<movement-model branch>/ml PY=<python with numpy> ghost/heldout/run.sh
#
# ML_DIR needs data/windows/*.npz (ml/prepare.py), runtime/MovementModel.swift and export/.
set -e
cd "$(dirname "$0")/../.."
ML_DIR=${ML_DIR:-../movement-model/ml}
PY=${PY:-python3}
if [ ! -f ghost/heldout/data/meta.json ]; then
    "$PY" -I ghost/heldout/export_cases.py "$ML_DIR" ghost/heldout/data
fi
mkdir -p ghost/heldout/.build
# The MeshCore sources the app ships (Ghost Mode plus the contract types it speaks).
find ios/MeshCore/Sources/MeshCore -name '*.swift' > ghost/heldout/.build/sources.txt
echo "$ML_DIR/runtime/MovementModel.swift" >> ghost/heldout/.build/sources.txt
echo ghost/heldout/main.swift >> ghost/heldout/.build/sources.txt
xargs swiftc -O -o ghost/heldout/.build/heldout < ghost/heldout/.build/sources.txt
ghost/heldout/.build/heldout ghost/heldout/data "$ML_DIR/export" ghost/results
