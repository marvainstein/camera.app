#!/usr/bin/env bash
# Corre todos los tests de los paquetes en el simulador de iOS (vía el scheme de la app).
# Uso: scripts/test.sh ["nombre del simulador"]
set -eu
cd "$(dirname "$0")/.."
sim="${1:-$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]+' | sed 's/ *$//')}"
echo "Simulador: $sim"
xcodebuild -workspace CameraApp.xcworkspace -scheme CameraApp \
  -destination "platform=iOS Simulator,name=$sim" \
  -derivedDataPath build/DerivedData test
