#!/usr/bin/env bash
#
# Regenerates every rasterised app icon from the two SVG sources.
#
#   app/assets/images/favicon-light.svg  -- red mark, used everywhere except
#                                           the dark-mode browser favicon
#   app/assets/images/favicon-dark.svg   -- navy mark, dark-mode favicon only
#
# Run it after editing either SVG:
#
#   script/generate_icons.sh
#
# Requires librsvg (`brew install librsvg`) and ImageMagick (`brew install
# imagemagick`). librsvg does the rasterising because ImageMagick's built-in
# SVG renderer drops the gradients and blur filters in these files.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC_LIGHT="app/assets/images/favicon-light.svg"
SRC_DARK="app/assets/images/favicon-dark.svg"
IMAGES="app/assets/images"
PUBLIC="public"

# The on-page logo (shared/_site_logo) is 32 CSS px. It used to point straight
# at the SVGs, but the scale glyph lives inside filter0_di (drop shadow + inner
# shadow) and a browser is free to rasterise a filter region at CSS resolution
# and upscale it, which on a 2x display softens the glyph while leaving the
# rounded rect sharp. Baking the exact device sizes below removes that variable.
LOGO_CSS_PX=32
LOGO_SCALES="1 2 3"

# Brand colours, kept in sync with the fills in the SVGs. The two pinks are the
# stops of the ring's linear gradient (paint1_linear), top to bottom.
RING_TOP="#FFE4E8"
RING_BOTTOM="#FEC2CA"

# The artwork is a 1229x1229 canvas: a pink ring around an inner rounded rect
# holding the red field and the scale.
#
# iOS and Android composite their own mask over whatever we hand them, and both
# reject transparency, so those icons need an opaque square. Do NOT get that by
# cropping the ring away: the ring is a *stroked* rounded rect, so it hugs the
# outer 70px along the flat edges but swings further inward around the corners.
# A fixed inset crop therefore cuts the border off the edges while leaving
# crescents of it stranded in the corners. Pad instead of crop -- fill the
# transparent corners with the ring's own gradient so the border stays whole and
# the fill reads as a continuation of it.
CANVAS=1229
SUPERSAMPLE=4                      # render at 4x the canvas, then downscale

for tool in rsvg-convert magick; do
  command -v "$tool" >/dev/null || { echo "missing dependency: $tool" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- masters -----------------------------------------------------------------
# Full canvas (ring included, transparent corners) -- what the browser favicon
# and the "any" manifest icons use, so they match the SVG favicon exactly.
rsvg-convert -w $(( CANVAS * SUPERSAMPLE )) -h $(( CANVAS * SUPERSAMPLE )) \
  "$SRC_LIGHT" -o "$work/full.png"

# Same again in navy, for the dark-mode on-page logo. Nothing else uses it: the
# home-screen and iOS icons are the red mark in both appearances.
rsvg-convert -w $(( CANVAS * SUPERSAMPLE )) -h $(( CANVAS * SUPERSAMPLE )) \
  "$SRC_DARK" -o "$work/full-dark.png"

# --- helpers -----------------------------------------------------------------
#
# `+dither -depth 8` on every write: ImageMagick works at a 16-bit quantum
# internally, and rounding that down on the way out sprays sub-LSB noise across
# the smooth gradient -- invisible (peak error is half an 8-bit level) but it
# wrecks PNG compression, costing ~5x on the gradient-backed icons.
from_full() { magick "$work/full.png" -resize "${1}x${1}" +dither -depth 8 -strip "$2"; }

# $1 master, $2 output size, $3 destination. Same downscale as from_full, but
# parameterised on the master so the navy logo can share it.
from_master() { magick "$1" -resize "${2}x${2}" +dither -depth 8 -strip "$3"; }

# $1 output size, $2 artwork size as a % of it, $3 destination. The whole
# artwork is scaled to fit and centred on an opaque ring-coloured gradient, so
# no part of the border is ever clipped.
on_ring_bg() {
  local size=$1 art=$(( $1 * $2 / 100 )) out=$3
  magick -size "${size}x${size}" "gradient:${RING_TOP}-${RING_BOTTOM}" \
    \( "$work/full.png" -resize "${art}x${art}" \) \
    -gravity center -composite -alpha remove -alpha off \
    +dither -depth 8 -strip "$out"
}

# --- browser favicons --------------------------------------------------------
for size in 16 32 48 96; do
  from_full "$size" "$IMAGES/favicon-${size}.png"
done

# Multi-resolution .ico for Safari, older browsers, and any client that just
# hits /favicon.ico without parsing the HTML (including our static 404/500
# pages, which reference no assets of their own).
magick "$IMAGES/favicon-16.png" "$IMAGES/favicon-32.png" "$IMAGES/favicon-48.png" \
  "$PUBLIC/favicon.ico"

# --- on-page logo ------------------------------------------------------------
# One PNG per device-pixel-ratio the logo can land on, wired up as a srcset in
# shared/_site_logo. Kept separate from the favicon-NN.png set: those are sized
# by what a browser asks for, these by what the page lays out, and the two are
# free to diverge.
for scale in $LOGO_SCALES; do
  size=$(( LOGO_CSS_PX * scale ))
  from_master "$work/full.png"      "$size" "$IMAGES/logo-${scale}x.png"
  from_master "$work/full-dark.png" "$size" "$IMAGES/logo-dark-${scale}x.png"
done

# --- iOS ---------------------------------------------------------------------
# 180x180, no alpha channel: iOS renders a transparent background as black.
# Full bleed is safe here. iOS masks with a squircle whose corners cut in less
# far than the artwork's own (rounder) corners do, so the mask boundary always
# falls outside the border -- only the gradient fill in the corners is trimmed.
on_ring_bg 180 100 "$IMAGES/apple-touch-icon.png"
cp "$IMAGES/apple-touch-icon.png" "$PUBLIC/apple-touch-icon.png"

# --- web app manifest --------------------------------------------------------
for size in 192 512; do
  from_full "$size" "$IMAGES/icon-${size}.png"
  # `purpose: maskable` icons only get the centre 80% of the canvas guaranteed,
  # and a launcher may mask to a full circle. At 70% the artwork's corners --
  # the outermost point of the border -- stay inside that circle, so the whole
  # ring survives whichever shape the launcher picks.
  on_ring_bg "$size" 70 "$IMAGES/icon-maskable-${size}.png"
done

# Rails' PWA scaffolding writes these two at the document root; keep them as
# real brand icons rather than the generated placeholders.
cp "$IMAGES/icon-512.png" "$PUBLIC/icon.png"
cp "$SRC_LIGHT" "$PUBLIC/icon.svg"

echo "Generated:"
ls -1 "$IMAGES"/favicon-*.png "$IMAGES"/logo-*.png "$IMAGES"/icon-*.png \
      "$IMAGES/apple-touch-icon.png" \
      "$PUBLIC/favicon.ico" "$PUBLIC/apple-touch-icon.png" "$PUBLIC/icon.png" "$PUBLIC/icon.svg"
