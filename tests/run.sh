#!/bin/bash
# Corre las pruebas de Soulstone con Lua 5.1 (la de WoW) dentro de Docker: el Mac no trae Lua.
set -euo pipefail
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD":/a -w /a alpine:3.20 sh -c '
  apk add -q lua5.1 >/dev/null
  for f in *.lua tests/*.lua; do luac5.1 -p "$f" || exit 1; done
  lua5.1 tests/speccopy.lua'
