#!/usr/bin/env bash
# idle-ops/install.sh
#
# Deploy completo e idempotente del stack idle-ops en el cluster.
# Puede ejecutarse multiples veces sin efectos secundarios:
#   - Los recursos existentes se actualizan (oc apply)
#   - El ConfigMap se recrea con el contenido actual de los archivos locales
#
# Requisito: estar logueado como cluster-admin.
#   El script crea ClusterRole y ClusterRoleBinding, que requieren
#   privilegios de administrador de cluster.
#
# Uso:
#   ./idle-ops/install.sh
#
# Para actualizar solo la lista de proyectos o el script sin redesplegar
# toda la infraestructura, ejecutar solo el paso 2 manualmente (ver abajo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

info()  { echo "[INFO ] $*"; }
ok()    { echo "[OK   ] $*"; }
warn()  { echo "[WARN ] $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Verificaciones previas
# ---------------------------------------------------------------------------
command -v oc &>/dev/null || die "oc no encontrado en PATH"
oc whoami &>/dev/null     || die "No autenticado. Ejecutar 'oc login' primero."

info "Cluster  : $(oc whoami --show-server)"
info "Usuario  : $(oc whoami)"

# ---------------------------------------------------------------------------
# 1. Aplicar manifests de infraestructura
#    Crea o actualiza (oc apply es idempotente):
#      - Namespace idle-ops
#      - ServiceAccount idle-manager
#      - ClusterRole idle-manager (permisos para oc idle y rollback)
#      - ClusterRoleBinding idle-manager (vincula el SA al ClusterRole)
#      - PVC idle-manager-data (almacena snapshots de estado y logs entre runs)
#      - CronJob idle-manager (ejecuta el script segun el schedule configurado)
# ---------------------------------------------------------------------------
info "Aplicando setup.yaml..."
oc apply -f "$SCRIPT_DIR/setup.yaml"
ok "Recursos de infraestructura aplicados."

# ---------------------------------------------------------------------------
# 2. Cargar el script y la lista de proyectos en un ConfigMap
#    Tecnica: --dry-run=client genera el YAML del ConfigMap sin aplicarlo,
#    luego oc apply hace upsert: crea si no existe, actualiza si ya existe.
#    Esto evita el error "already exists" de oc create sin --dry-run.
#
#    El ConfigMap contiene dos claves:
#      - oc-idle-manager.sh : script principal ejecutado por el CronJob
#      - projects.txt       : lista de namespaces a gestionar
#
#    Para actualizar solo estos archivos sin redeployar toda la infra,
#    ejecutar este bloque manualmente.
# ---------------------------------------------------------------------------
info "Cargando ConfigMap idle-manager-script..."

PROJECTS_FILE="$SCRIPT_DIR/projects.txt"
SCRIPT_FILE="$ROOT_DIR/oc-idle-manager.sh"

[[ -f "$SCRIPT_FILE" ]]   || die "No se encontro: $SCRIPT_FILE"
[[ -f "$PROJECTS_FILE" ]] || die "No se encontro: $PROJECTS_FILE"

oc create configmap idle-manager-script \
    --from-file=oc-idle-manager.sh="$SCRIPT_FILE" \
    --from-file=projects.txt="$PROJECTS_FILE" \
    -n idle-ops \
    --dry-run=client -o yaml | oc apply -f -

ok "ConfigMap idle-manager-script actualizado."

# ---------------------------------------------------------------------------
# 3. Verificacion final
#    Muestra el estado de todos los recursos gestionados por idle-ops.
#    Usar este output para confirmar que el deploy fue exitoso antes de
#    esperar la primera ejecucion automatica del CronJob.
# ---------------------------------------------------------------------------
echo ""
info "Estado actual en idle-ops:"
oc get serviceaccount,clusterrolebinding,pvc,configmap,cronjob -n idle-ops \
    --ignore-not-found \
    -l app.kubernetes.io/name=idle-manager

echo ""
ok "Instalacion completada."
echo ""
echo "Proximos pasos:"
echo "  1. Editar idle-ops/projects.txt con los proyectos a gestionar"
echo "  2. Volver a ejecutar este script para actualizar el ConfigMap"
echo "  3. Verificar permisos del SA en un proyecto target:"
echo "       oc auth can-i idle services \\"
echo "         --as=system:serviceaccount:idle-ops:idle-manager \\"
echo "         -n <proyecto-target>"
echo "  4. Para un rollback manual inmediato:"
echo "       oc create job --from=cronjob/idle-manager idle-rollback-manual -n idle-ops"
echo "       # Editar el Job para cambiar los args a 'rollback -f /scripts/projects.txt'"
echo "  5. Ver logs del ultimo Job:"
echo "       oc logs -l app.kubernetes.io/name=idle-manager -n idle-ops --tail=100"
