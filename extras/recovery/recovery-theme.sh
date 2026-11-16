#!/usr/bin/env bash
# Recovery + fastbootd theme (2026-11-14): Everforest colours and our emblem in
# LineageOS recovery's images, for every density directory given.
#   recovery  = aqua / green   (was purple / pink)
#   fastbootd = orange / yellow, Everforest tones (was #E65100 / #FDD835) — the two
#               modes must stay easy to tell apart
# Images per res-*/images dir:
#   logo_image*.png, fastbootd.png  recoloured (hue mapping, frame + R/F markers and
#                                   text kept), centre LineageOS symbol → emblem
#   ic_back_sel.png                 recoloured
#   loop*.png (install animation)   emblem pulsing gently, same frame count
# The menu/header colours are in code: patches/bootable/recovery/.
#   extras/recovery/recovery-theme.sh <emblem.png> <res-*/images dir>...
set -euo pipefail
if command -v magick >/dev/null; then im() { magick "$@"; }; idn() { magick identify "$@"; }
else im() { convert "$@"; }; idn() { identify "$@"; }; fi
emblem=$1; shift

# minui (recovery's image loader) accepts only 8-bit RGB, grey or palette PNGs, no
# alpha (minui/resources.cpp): flatten onto black, write 8-bit RGB
finalize() { im "$1" -background black -alpha remove -alpha off -depth 8 "PNG24:$1"; }
check_png() {
  local t; t=$(im identify -format '%[png:IHDR.bit-depth-orig] %[png:IHDR.color-type-orig]' "$1" 2>/dev/null \
            || idn -format '%[png:IHDR.bit-depth-orig] %[png:IHDR.color-type-orig]' "$1")
  case "$t" in "8 2"|"8 0"|"8 3") ;; *) echo "minui can't load $1 (depth/type $t)"; exit 1 ;; esac
}

# HSL hue mapping (R=hue, G=saturation, B=lightness, 0..1). Only saturated pixels in
# the listed hue bands change; greys/white/black (and their antialiasing) stay.
#   purple 0.62-0.78 → aqua   #83C092 (h 0.38, desaturated)
#   pink   0.78-0.95 → green  #A7C080 (h 0.23)
#   orange 0.00-0.10 → orange #E69875 (h 0.058, lighter)
#   yellow 0.10-0.20 → yellow #DBBC7F (h 0.11)
recolor() {
  local sat="u.g<0.15"
  im "$1" -colorspace HSL \
    -channel B -fx "($sat) ? u.b : (u.r<0.10) ? min(1,u.b*1.3) : u.b" \
    -channel G -fx "($sat) ? u.g : (u.r>=0.62&&u.r<0.78) ? u.g*0.35 : (u.r>=0.78&&u.r<0.95) ? u.g*0.38 : (u.r<0.10) ? u.g*0.7 : (u.r>=0.10&&u.r<0.20) ? u.g*0.55 : u.g" \
    -channel R -fx "($sat) ? u.r : (u.r>=0.62&&u.r<0.78) ? 0.38 : (u.r>=0.78&&u.r<0.95) ? 0.23 : (u.r<0.10) ? 0.058 : (u.r>=0.10&&u.r<0.20) ? 0.11 : u.r" \
    +channel -colorspace sRGB "$1"
}

# replace the white LineageOS symbol in the middle of a header logo with the emblem:
# find it in the centre box, black it out, emblem 2.5x the symbol's height
emblemize() {
  local f=$1 w h bx by bw bh x0 y0 sw sh cx cy d m tmp
  read -r w h < <(idn -format '%w %h\n' "$f")
  bx=$((w * 3 / 10)); by=$((h * 3 / 10)); bw=$((w * 4 / 10)); bh=$((h * 3 / 10))
  read -r sw sh x0 y0 < <(im "$f" -crop "${bw}x${bh}+${bx}+${by}" +repage -colorspace Gray \
      -threshold 60% -trim -format '%w %h %X %Y\n' info: | tr -d '+')
  cx=$((bx + x0 + sw / 2)); cy=$((by + y0 + sh / 2))
  d=$((sh * 5 / 2)); m=$((sh / 6 + 2))
  [ "$sw" -gt $((w / 10)) ] && [ "$sh" -gt $((h / 20)) ] || { echo "no symbol found in $f"; exit 1; }
  tmp=$(mktemp --suffix=.png)
  im "$emblem" -resize "${d}x${d}" "$tmp"
  im "$f" -fill black -draw "rectangle $((bx + x0 - m)),$((by + y0 - m)) $((bx + x0 + sw + m)),$((by + y0 + sh + m))" \
     "$tmp" -geometry "+$((cx - d / 2))+$((cy - d / 2))" -compose Lighten -composite "$f"
  rm -f "$tmp"
}

for dir in "$@"; do
  for f in "$dir"/logo_image.png "$dir"/logo_image_switch.png "$dir"/fastbootd.png; do
    [ -f "$f" ] || continue
    recolor "$f"; emblemize "$f"; finalize "$f"; check_png "$f"; echo "  theme: $f"
  done
  if [ -f "$dir/ic_back_sel.png" ]; then
    recolor "$dir/ic_back_sel.png"; finalize "$dir/ic_back_sel.png"; check_png "$dir/ic_back_sel.png"
    echo "  theme: $dir/ic_back_sel.png"
  fi
  mapfile -t loops < <(ls "$dir"/loop*.png 2>/dev/null | sort)
  if [ "${#loops[@]}" -gt 0 ]; then
    read -r w h < <(idn -format '%w %h\n' "${loops[0]}")
    d=$((h * 7 / 10)); n=${#loops[@]}; tmp=$(mktemp --suffix=.png)
    im "$emblem" -resize "${d}x${d}" "$tmp"
    for i in "${!loops[@]}"; do
      # brightness 65..100 %, one smooth pulse per loop
      b=$(awk -v i="$i" -v n="$n" 'BEGIN { printf "%d", 82.5 - 17.5 * cos(2 * 3.14159265 * i / n) }')
      im -size "${w}x${h}" xc:black \( "$tmp" -modulate "$b" \) -gravity center -composite \
         -alpha off -depth 8 "PNG24:${loops[$i]}"
      check_png "${loops[$i]}"
    done
    rm -f "$tmp"; echo "  theme: $dir/loop*.png ($n frames)"
  fi
done
