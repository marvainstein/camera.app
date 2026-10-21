#!/usr/bin/env bash
# Compila la app y corre todos los tests de los paquetes en el simulador de iOS.
# Uso: scripts/test.sh ["nombre del simulador"]
# Sin argumento usa el primer iPhone del runtime de iOS más nuevo instalado.
# XCODEBUILD_FLAGS agrega opciones a xcodebuild (en CI: CODE_SIGNING_ALLOWED=NO).
set -eu
cd "$(dirname "$0")/.."
if [ $# -gt 0 ]; then
  destination="platform=iOS Simulator,name=$1"
else
  udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
ios = sorted((k for k in devices if ".iOS-" in k),
             key=lambda k: [int(x) for x in k.rsplit(".iOS-", 1)[1].split("-")])
for runtime in reversed(ios):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"]); break
')"
  [ -n "$udid" ] || { echo "No hay simuladores de iPhone disponibles" >&2; exit 1; }
  destination="platform=iOS Simulator,id=$udid"
fi
echo "Destino: $destination"
xcodebuild -workspace CameraApp.xcworkspace -scheme CameraApp \
  -destination "$destination" \
  -derivedDataPath build/DerivedData ${XCODEBUILD_FLAGS:-} test
