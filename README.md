# Plantillas DevSecOps · despliegue de BD (laboratorio)

Workflows reutilizables y scripts para versionar y desplegar los cambios de base de datos de INSIS con Liquibase (SQLcl).
Este repo es de **DevSecOps**: los repos de BD solo traen sus scripts de migración y unos workflows que llaman a estas
plantillas con una versión fija (`@v2`). Así, un PR del repo de BD no puede cambiar la validación ni el despliegue.

## Workflows (`workflow_call`)

| Workflow | Lo llama el repo de BD en | Qué hace |
| --- | --- | --- |
| `bd-validar-pr.yml` | PR a desa, test y prod | Reglas de promoción, nomenclatura y scripts; en prod, que el contenido esté certificado en test; plan en desa |
| `bd-desplegar-desa.yml` | push a desa | `update` y `status` en desa |
| `bd-etiquetar.yml` | push a test / prod | Crea `test-vX.Y.0` (siguiente versión) o `prod-vX.Y.0` (la certificada en test) |
| `bd-desplegar.yml` | lanzamiento manual en test / prod (ticket de Ivanti) | CI: plan, OPA y PRA → aprobación del environment → CD: update, etiqueta en la base, EPP |
| `bd-rollback.yml` | lanzamiento manual en prod | Vuelve prod a una etiqueta `prod-v*` desplegada antes |

Cada job hace checkout del repo de BD que llama y de este repo (en `.plantillas/`) con la versión del input `plantillas`
(por defecto `v2`, la misma etiqueta con la que se llama el workflow).

## Scripts

Se ejecutan con el repo de BD como directorio de trabajo (o `REPO_BD=<ruta>`), que solo trae
`oracle-insis/migrations/<ESQUEMA>/changelog.xml` y sus scripts: cada carpeta es un esquema.

La conexión llega en variables de cada environment (`DB_HOST`, `DB_PORT`, `DB_SERVICE`, `DB_USER`) y la clave en el
secreto `INSIS_DEPLOY_PASSWORD`. El repo de BD no tiene datos de conexión.

Solo se procesan los esquemas con archivos cambiados desde el último despliegue exitoso del ambiente (`LB_DESDE`, que
calcula `desplegado.sh`). El orden entre esquemas sale de la menor versión `V<n>.<m>` de sus scripts cambiados: las
versiones no se repiten en el repo, así que el desarrollador fija el orden al numerar. El rollback va en orden inverso.

| Script | Uso |
| --- | --- |
| `lb.sh <amb> <comando>` | Liquibase en cada esquema por proxy (`INSIS_DEPLOY[ESQUEMA]`): validate, status, update, update-sql, future-rollback-sql, tag, rollback, rollback-sql |
| `validar.py <rama-base>` | Compuerta del PR: nombres, cabecera Liquibase, `--rollback`, inclusión en changelog, sentencias prohibidas, scripts ya integrados sin cambios |
| `esquemas.sh <carpeta>` | Esquemas a procesar, en orden (con `LB_DESDE`, solo los cambiados) |
| `desplegado.sh <amb>` | Commit del último despliegue exitoso en el environment |
| `version.sh` | `siguiente`, `de <amb> <commit>`, `certificada <commit>`: versión calculada desde las etiquetas |
| `documentos.sh opa\|epp` | Entregables OPA/PRA (plan) y EPP (despliegue) en Markdown |

## Versiones de las plantillas

Los cambios entran por PR a `main` y se publican con una etiqueta (`v2.0.0`) y la etiqueta móvil `v2`, que es la que
usan los repos de BD. Un cambio incompatible pasa a `v3`, y cada repo de BD actualiza su llamada cuando corresponda.

## Requisitos del runner (`self-hosted`, etiqueta `insis-db`)

Java 17, SQLcl (con Liquibase) en el PATH y acceso de red a las bases de desa, test y prod.
