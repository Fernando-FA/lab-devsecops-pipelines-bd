#!/usr/bin/env bash
# Ejecuta un comando de Liquibase (SQLcl) en cada esquema de INSIS, entrando por proxy con INSIS_DEPLOY.
# Uso: lb.sh <desa|test|prod> <comando> [argumentos de liquibase]
#   comandos: validate | status | update | update-sql | future-rollback-sql | tag <t> | rollback <t> | rollback-sql <t>
# Variables: DB_HOST, DB_PORT, DB_SERVICE, DB_USER e INSIS_DEPLOY_PASSWORD (obligatorias; las da el environment del ambiente),
# LB_DESDE (commit ya desplegado en el ambiente: solo se procesan los esquemas cambiados desde ahí; vacío = todos; en rollback,
# por defecto la etiqueta destino), REPO_BD (repo de BD; por defecto el directorio actual), LB_DIR (carpeta con un subdirectorio
# por esquema; por defecto oracle-insis/migrations), LB_SALIDA (carpeta donde dejar el log de cada esquema).
set -euo pipefail
raiz="$(cd "${REPO_BD:-.}" && pwd)"  # repo de BD (por defecto, el directorio actual)
amb="${1:?ambiente}"; cmd="${2:?comando}"; shift 2
for v in DB_HOST DB_PORT DB_SERVICE DB_USER INSIS_DEPLOY_PASSWORD; do
  [ -n "${!v:-}" ] || { echo "Falta la variable $v (se define en el environment del ambiente)" >&2; exit 2; }
done
lb_dir="${LB_DIR:-$raiz/oracle-insis/migrations}"
salida="${LB_SALIDA:-$raiz/evidencia/$amb}"
mkdir -p "$salida"

[[ "$cmd" == rollback* ]] && LB_DESDE="${LB_DESDE:-$1}"
lista=$(LB_DESDE="${LB_DESDE:-}" "$(dirname "$0")/esquemas.sh" "$lb_dir") || { echo "No se pudo calcular los esquemas desde ${LB_DESDE:-}" >&2; exit 2; }
[ -n "$lista" ] || { echo "Sin cambios de base de datos desde ${LB_DESDE:-el inicio}: nada que hacer"; exit 0; }
mapfile -t esquemas <<<"$lista"
[[ "$cmd" == rollback* ]] && mapfile -t esquemas < <(printf '%s\n' "${esquemas[@]}" | tac)
alcance="todos"; [ -n "${LB_DESDE:-}" ] && alcance="cambiados desde ${LB_DESDE:0:12}"
echo "Esquemas ($amb, $alcance): ${esquemas[*]}"

case "$cmd" in
  tag)                   nueva="$1"; cmd=update; args="" ;;
  rollback|rollback-sql) args="-tag $1" ;;
  validate|status|update|update-sql|future-rollback-sql) args="$*" ;;
  *) echo "Comando no soportado: $cmd" >&2; exit 2 ;;
esac
[ "$cmd" = status ] && args="$args -verbose true"
accion="${nueva:+tag}"; accion="${accion:-$cmd}"

conectar() { echo "connect $DB_USER[$1]/\"$INSIS_DEPLOY_PASSWORD\"@//$DB_HOST:$DB_PORT/$DB_SERVICE"; }

# Cada etiqueta de despliegue es su propia fila en DATABASECHANGELOG: un changeset tagDatabase (autor "pipeline").
# El comando "liquibase tag" de Liquibase la escribiría en la última fila aplicada, y esa fila se pisa cuando un
# esquema no tiene cambios o cuando se reaplica un script runOnChange (code/): el rollback a esa etiqueta no haría nada.
# La envoltura incluye el changelog del esquema más las etiquetas ya registradas en la base (y la nueva, si se pide),
# para que Liquibase las conozca al hacer rollback. Liquibase también deshace la fila de la etiqueta destino: tras un
# rollback se vuelve a registrar, para que la base quede marcada con la versión a la que volvió.
# Como solo se despliegan los esquemas con cambios, un esquema no tiene todas las etiquetas. Antes de su primer cambio
# por el pipeline se registra <amb>-base (su estado previo), y el rollback a una versión usa, en cada esquema, la etiqueta
# más reciente que no la supera (o <amb>-base si no hay ninguna).
etiquetas_de() {  # esquema → etiquetas del pipeline registradas, en orden de aplicación
  sql -S -L /nolog <<SQL | tr -d '\r' | sed 's/[[:space:]]*$//' | grep -E '^[a-z]+-(v[0-9]|base$)' || true
$(conectar "$1")
set heading off feedback off pagesize 0
whenever sqlerror continue
select id from databasechangelog where author = 'pipeline' order by orderexecuted;
exit
SQL
}
envoltura() {  # esquema, carpeta → escribe <carpeta>/.lb-<amb>.xml
  local etiquetas base=""
  etiquetas=$(etiquetas_de "$1")
  [ -z "$etiquetas" ] && [ -z "${solo_etiquetas:-}" ] && base="$amb-base"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog"'
    echo '    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">'
    [ -n "$base" ] && echo "  <changeSet id=\"$base\" author=\"pipeline\" logicalFilePath=\"pipeline/etiquetas\"><tagDatabase tag=\"$base\"/></changeSet>"
    [ -z "${solo_etiquetas:-}" ] && echo '  <include file="changelog.xml" relativeToChangelogFile="true"/>'
    for t in $etiquetas ${nueva:-}; do
      echo "  <changeSet id=\"$t\" author=\"pipeline\" logicalFilePath=\"pipeline/etiquetas\"><tagDatabase tag=\"$t\"/></changeSet>"
    done
    echo '</databaseChangeLog>'
  } | awk '!visto[$0]++' > "$2/.lb-$amb.xml"
}

# Etiqueta del pipeline a la que vuelve un esquema para quedar como en la versión <destino>: la más reciente que no la supera.
etiqueta_destino() {  # esquema, destino
  local t mejor=""
  for t in $(etiquetas_de "$1"); do
    [[ "$t" == "$amb-v"* ]] || continue
    [ "$(printf '%s\n%s\n' "${t#"$amb"-v}" "${2#"$amb"-v}" | sort -V | head -1)" = "${t#"$amb"-v}" ] && mejor="$t"
  done
  [ -z "$mejor" ] && etiquetas_de "$1" | grep -qx "$amb-base" && mejor="$amb-base"
  echo "$mejor"
}

fallo=0
for esq in "${esquemas[@]}"; do
  dir="$lb_dir/$esq"
  if [ ! -f "$dir/changelog.xml" ]; then echo "== $esq: sin changelog.xml, se omite"; continue; fi
  log="$salida/$esq.$accion.log"
  if [[ "$cmd" == rollback* ]]; then
    # Solo se vuelve a etiquetas registradas por el pipeline (filas tagDatabase). Una etiqueta escrita en otra fila
    # puede haber quedado después de los cambios que se quieren deshacer y el rollback no haría nada.
    destino=$(etiqueta_destino "$esq" "$1")
    [ -n "$destino" ] || { echo "!! $esq: no tiene una etiqueta del pipeline igual o anterior a $1; no se puede volver a ella" >&2; fallo=1; break; }
    args="-tag $destino"
  fi
  envoltura "$esq" "$dir"
  echo "== $amb · $esq · liquibase $accion ${nueva:-${destino:-${1:-}}}"
  sql -S -L /nolog > "$log" 2>&1 <<SQL || true
$(conectar "$esq")
cd $dir
liquibase $cmd $args -changelog-file .lb-$amb.xml
exit
SQL
  sed -e '/^--Starting Liquibase/d' "$log"
  if ! grep -q 'Operation completed successfully' "$log"; then
    echo "!! $esq: liquibase $accion falló (log: $log)" >&2
    fallo=1
    break
  fi
  if [ "$cmd" = rollback ]; then
    # Solo la etiqueta: con el changelog completo, el update volvería a aplicar lo que se acaba de deshacer.
    nueva="$destino" solo_etiquetas=1 envoltura "$esq" "$dir"
    sql -S -L /nolog > "$salida/$esq.retag.log" 2>&1 <<SQL || true
$(conectar "$esq")
cd $dir
liquibase update -changelog-file .lb-$amb.xml
exit
SQL
    grep -q 'Operation completed successfully' "$salida/$esq.retag.log" && echo "   $esq: etiqueta $destino registrada de nuevo" \
      || { echo "!! $esq: no se pudo volver a registrar $destino" >&2; fallo=1; break; }
  fi
done
exit $fallo
