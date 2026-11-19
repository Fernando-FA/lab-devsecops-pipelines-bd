#!/usr/bin/env bash
# Lista, en orden de despliegue, los esquemas de <carpeta> (una subcarpeta por esquema, con su changelog.xml).
#   Con LB_DESDE=<commit> (lo último desplegado en el ambiente): solo los esquemas con archivos cambiados desde ese commit.
#   Sin LB_DESDE: todos.
# Orden: la menor versión V<n>.<m> de los scripts considerados de cada esquema. Las versiones son únicas en el repo,
# así que el desarrollador define el orden entre esquemas al numerar. Los esquemas con cambios solo en code/ van al final.
set -euo pipefail
cd "${1:?carpeta de esquemas}"
if [ -n "${LB_DESDE:-}" ]; then
  git diff --name-only --relative "$LB_DESDE" HEAD -- .
else
  find . -mindepth 2 -type f ! -name '.*' | sed 's|^\./||'
fi | awk -F/ 'NF >= 2 {
  v = "~"
  if (match($NF, /^V[0-9]+\.[0-9]+_/)) { split(substr($NF, 2, RLENGTH - 2), p, "."); v = sprintf("%09d.%09d", p[1], p[2]) }
  if (!($1 in m) || v < m[$1]) m[$1] = v
} END { for (e in m) print m[e], e }' | LC_ALL=C sort | awk '{ print $2 }'
