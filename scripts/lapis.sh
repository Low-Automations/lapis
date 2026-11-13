#!/usr/bin/env bash
# Gestión del paquete local de Lapis (ver .docker/lapis/compose.yml).
# Solo toca recursos Docker del proyecto "lapis"; nunca otros proyectos.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/.docker/lapis/compose.yml")
PORT="${LAPIS_PORT:-3010}"
BACKUP_DIR="${LAPIS_BACKUP_DIR:-$HOME/lapis-backups}"
BACKUP_KEEP="${LAPIS_BACKUP_KEEP:-5}"
VOLUMES=(lapis_postgres lapis_storage lapis_config)

say() { printf '\033[1;34m[lapis]\033[0m %s\n' "$*"; }

image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

cmd_up() {
  say "Iniciando base de datos y caché…"
  "${COMPOSE[@]}" up -d --wait postgres redis
  say "Aplicando migraciones (contenedor efímero)…"
  "${COMPOSE[@]}" run --rm migrate
  say "Iniciando servidor…"
  "${COMPOSE[@]}" up -d --wait server
  say "Listo: http://localhost:$PORT  (admin inicial: http://localhost:$PORT/admin)"
}

cmd_down() {
  "${COMPOSE[@]}" --profile tools down --remove-orphans
  say "Parado. Los datos siguen en los volúmenes: ${VOLUMES[*]}"
}

cmd_status() {
  "${COMPOSE[@]}" ps
  echo
  docker system df -v 2>/dev/null | grep -E '^(VOLUME NAME|lapis_)' || true
}

cmd_logs() { "${COMPOSE[@]}" logs -f --tail=200 "${@:-server}"; }

cmd_backup() {
  mkdir -p "$BACKUP_DIR"
  local stamp dest
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/lapis-$stamp"
  mkdir "$dest"
  say "Volcando base de datos…"
  "${COMPOSE[@]}" exec -T postgres pg_dump -U lapis -d lapis -Fc >"$dest/db.dump"
  say "Copiando archivos subidos y clave privada…"
  for v in lapis_storage lapis_config; do
    docker run --rm -v "$v:/src:ro" alpine tar -C /src -czf - . >"$dest/$v.tar.gz"
  done
  say "Backup: $dest"
  # Rotación: conservar solo los $BACKUP_KEEP más recientes.
  ls -1d "$BACKUP_DIR"/lapis-* 2>/dev/null | sort -r | tail -n +"$((BACKUP_KEEP + 1))" | while read -r old; do
    say "Borrando backup antiguo: $old"
    rm -rf -- "$old"
  done
}

cmd_update() {
  local img old
  img="$("${COMPOSE[@]}" config --images | grep -v -E 'redis|pgvector' | head -1)"
  old="$(image_id "$img")"
  "${COMPOSE[@]}" --profile tools pull
  cmd_up
  if [[ -n "$old" && "$old" != "$(image_id "$img")" ]]; then
    say "Borrando imagen anterior del servidor…"
    docker image rm "$old" >/dev/null 2>&1 || true
  fi
}

cmd_clean() {
  say "Borrando contenedores parados y volúmenes anónimos de lapis…"
  docker container prune -f --filter label=com.docker.compose.project=lapis >/dev/null
  docker volume ls -q --filter label=com.docker.compose.project=lapis --filter dangling=true \
    | grep -v -x -F -f <(printf '%s\n' "${VOLUMES[@]}") \
    | xargs -r docker volume rm >/dev/null || true
  say "Limpio. Datos conservados: ${VOLUMES[*]}"
}

cmd_reset() {
  say "Esto BORRA todos los datos de lapis (${VOLUMES[*]}). No se puede deshacer."
  read -r -p "Escribe 'lapis' para confirmar: " ok
  [[ "$ok" == "lapis" ]] || { say "Cancelado."; exit 1; }
  "${COMPOSE[@]}" --profile tools down --remove-orphans --volumes
  say "Datos borrados."
}

case "${1:-help}" in
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  logs) shift; cmd_logs "$@" ;;
  backup) cmd_backup ;;
  update) cmd_update ;;
  clean) cmd_clean ;;
  reset) cmd_reset ;;
  *)
    cat <<EOF
Uso: scripts/lapis.sh <comando>
  up       Arranca lapis (migra y levanta) en http://localhost:$PORT
  down     Para todo (los datos se conservan)
  status   Estado de servicios y tamaño de volúmenes
  logs     Sigue logs (por defecto del servidor; ej: logs postgres)
  backup   Copia DB + archivos a $BACKUP_DIR (guarda los $BACKUP_KEEP últimos)
  update   Descarga la última imagen, migra y borra la imagen vieja
  clean    Borra restos (contenedores parados, volúmenes anónimos) de lapis
  reset    Borra TODOS los datos de lapis (pide confirmación)
EOF
    ;;
esac
