#!/usr/bin/env bash
# demo-apps/deploy-all.sh
# Despliega los tres proyectos demo y muestra las URLs de acceso.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { echo "[INFO ] $*"; }
ok()    { echo "[OK   ] $*"; }
warn()  { echo "[WARN ] $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }
sep()   { echo ""; echo "─────────────────────────────────────────────"; }

# ---------------------------------------------------------------------------
command -v oc &>/dev/null || die "oc no encontrado en PATH"
oc whoami &>/dev/null     || die "No autenticado. Ejecutar 'oc login' primero."

info "Cluster : $(oc whoami --show-server)"
info "Usuario : $(oc whoami)"

# ---------------------------------------------------------------------------
sep
info "Aplicando manifests..."

APPS=("python-demo" "node-demo" "java-demo")
FILES=("python-demo.yaml" "node-demo.yaml" "java-demo.yaml")

for i in "${!FILES[@]}"; do
    info "Aplicando ${FILES[$i]}..."
    oc apply -f "$SCRIPT_DIR/${FILES[$i]}"
    ok "${APPS[$i]} aplicado."
done

# ---------------------------------------------------------------------------
sep
info "Esperando que los Deployments esten listos..."

dep_name() {
    case "$1" in
        python-demo) echo "python-app" ;;
        node-demo)   echo "node-app"   ;;
        java-demo)   echo "java-app"   ;;
    esac
}

for ns in "${APPS[@]}"; do
    dep="$(dep_name "$ns")"
    info "Esperando deployment/$dep en namespace $ns..."
    # Java tiene un initContainer que compila, puede tardar un poco mas
    if ! oc rollout status deployment/"$dep" -n "$ns" --timeout=180s; then
        warn "Timeout esperando $dep en $ns. Verificar con: oc logs -n $ns -l app=$dep"
    else
        ok "$dep en $ns listo."
    fi
done

# ---------------------------------------------------------------------------
sep
info "Actualizando idle-ops/projects.txt..."

PROJECTS_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/idle-ops/projects.txt"
if [[ -f "$PROJECTS_FILE" ]]; then
    # Agrega los proyectos demo si no estan ya
    for app in "${APPS[@]}"; do
        if ! grep -q "^${app}$" "$PROJECTS_FILE" 2>/dev/null; then
            echo "$app" >> "$PROJECTS_FILE"
            ok "Agregado '$app' a projects.txt"
        else
            info "'$app' ya estaba en projects.txt"
        fi
    done
else
    warn "No se encontro $PROJECTS_FILE. Actualizar manualmente."
fi

# ---------------------------------------------------------------------------
sep
echo ""
echo "  RESUMEN DE APLICACIONES"
echo ""
printf "  %-14s %-12s %-8s %s\n" "PROYECTO" "APP" "PODS" "ROUTE"
printf "  %-14s %-12s %-8s %s\n" "-------" "---" "----" "-----"

for ns in "${APPS[@]}"; do
    dep="$(dep_name "$ns")"
    route=$(oc get route "$dep" -n "$ns" \
        -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "(sin route)")
    ready=$(oc get deployment "$dep" -n "$ns" \
        -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "?")
    printf "  %-14s %-12s %-8s %s\n" "$ns" "$dep" "$ready" "$route"
done

echo ""
echo "  Para probar:"
for ns in "${APPS[@]}"; do
    dep="$(dep_name "$ns")"
    route=$(oc get route "$dep" -n "$ns" \
        -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    [[ -n "$route" ]] && echo "    curl $route"
done
echo ""
