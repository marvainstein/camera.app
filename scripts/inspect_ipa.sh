#!/usr/bin/env bash
# Inventaria una IPA (cifrada con FairPlay o no) sin ejecutar nada de su contenido.
# Uso: scripts/inspect_ipa.sh /ruta/a/App.ipa [dir_salida]
# Deja en dir_salida (default: ./re-out/<nombre-ipa>) un reporte de texto por categoría.
set -eu

ipa="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
name="$(basename "$ipa" .ipa)"
out="${2:-$PWD/re-out/$name}"
work="$out/extracted"

rm -rf "$out" && mkdir -p "$work"
unzip -q "$ipa" -d "$work"
app="$(find "$work/Payload" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$app" ] || { echo "No se encontró Payload/*.app" >&2; exit 1; }
exe="$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"

section() { printf '\n===== %s =====\n' "$1"; }

{
  section "Info.plist"
  plutil -p "$app/Info.plist"

  section "Entitlements"
  codesign -d --entitlements :- "$app" 2>/dev/null | plutil -p - || echo "(no disponibles)"

  section "Cifrado FairPlay (cryptid 1 = cifrado)"
  otool -l "$exe" | grep -A4 LC_ENCRYPTION_INFO || echo "(sin LC_ENCRYPTION_INFO)"

  section "Dylibs enlazadas"
  otool -L "$exe"
} > "$out/01-app.txt"

{
  section "Frameworks embebidos"
  for fw in "$app"/Frameworks/*; do
    plist="$fw/Info.plist"
    if [ -f "$plist" ]; then
      printf '%s\t%s\t%s\n' "$(basename "$fw")" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || echo '?')" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || echo '?')"
    else
      basename "$fw"
    fi
  done

  section "Extensiones (PlugIns / Extensions)"
  for ext in "$app"/PlugIns/*.appex "$app"/Extensions/*.appex; do
    [ -e "$ext" ] || continue
    echo "--- $(basename "$ext")"
    plutil -p "$ext/Info.plist" | grep -E 'CFBundleIdentifier|NSExtensionPointIdentifier|EXExtensionPointIdentifier|NSExtensionPrincipalClass' || true
    codesign -d --entitlements :- "$ext" 2>/dev/null | plutil -p - 2>/dev/null || true
  done
} > "$out/02-frameworks-extensions.txt"

{
  section "Tipos de archivo por extensión (cantidad, bytes)"
  find "$app" -type f | awk -F/ '{f=$NF; e=(index(f,".")?tolower(substr(f,match(f,/\.[^.]*$/)+1)):"(none)"); print e}' \
    | sort | uniq -c | sort -rn

  section "Los 60 archivos más grandes"
  find "$app" -type f -exec stat -f '%z %N' {} + | sort -rn | head -60 | sed "s|$app/||"

  section "Modelos CoreML"
  find "$app" -name '*.mlmodelc' -type d | sed "s|$app/||"
  find "$app" -name '*.mlmodelc' -type d -print0 | while IFS= read -r -d '' m; do
    echo "--- $(basename "$m")"
    if [ -f "$m/metadata.json" ]; then head -c 4000 "$m/metadata.json"; echo; fi
  done

  section "Candidatos a LUT / looks (cube, 3dl, png/bin con nombres de look)"
  find "$app" -type f \( -iname '*.cube' -o -iname '*.3dl' -o -iname '*lut*' -o -iname '*look*' -o -iname '*.json' \) \
    | sed "s|$app/||" | head -300
} > "$out/03-recursos.txt"

{
  section "Funciones en metallibs (nombres de kernels/shaders)"
  find "$app" -name '*.metallib' -print0 | while IFS= read -r -d '' lib; do
    echo "--- ${lib#"$app"/}"
    strings -a "$lib" | grep -E '^[A-Za-z_][A-Za-z0-9_]{3,}$' | sort -u | head -400
  done
} > "$out/04-metal.txt"

{
  section "Strings localizados (en)"
  find "$app" \( -path '*en.lproj/*.strings' -o -path '*en.lproj/*.stringsdict' -o -name '*.loctable' -o -name '*.xcstrings' \) -print0 \
    | while IFS= read -r -d '' f; do
      echo "--- ${f#"$app"/}"
      plutil -p "$f" 2>/dev/null || cat "$f"
    done
} > "$out/05-strings-ui.txt"

{
  section "Asset catalogs"
  find "$app" -name '*.car' -print0 | while IFS= read -r -d '' car; do
    echo "--- ${car#"$app"/}"
    xcrun --sdk iphoneos assetutil --info "$car" 2>/dev/null \
      | grep -E '"(Name|RenditionName|AssetType)"' | sort -u | head -500
  done
} > "$out/06-assets.txt"

{
  section "URLs y hosts en recursos y binario (los binarios cifrados darán poco)"
  grep -rhoaE 'https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+' "$app" 2>/dev/null | sort -u | head -500
} > "$out/07-urls.txt"

echo "Reporte en: $out"
ls -1 "$out"
