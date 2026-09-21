# oc-idle-manager

Solución para gestionar automáticamente el estado idle/activo de servicios en proyectos OpenShift 4.18+. Ejecuta `oc idle` mediante un CronJob en el proyecto dedicado `idle-ops`, con capacidad de rollback basado en snapshots de estado previo.

---

## Tabla de contenidos

1. [Visión general](#1-visión-general)
2. [Estructura del repositorio](#2-estructura-del-repositorio)
3. [Prerequisitos](#3-prerequisitos)
4. [Modelo RBAC — Opción A (ClusterRoleBinding)](#4-modelo-rbac--opción-a-clusterrolebinding)
5. [Recursos OpenShift en detalle](#5-recursos-openshift-en-detalle)
6. [El script oc-idle-manager.sh](#6-el-script-oc-idle-managersh)
7. [Aplicaciones demo](#7-aplicaciones-demo)
8. [Instalación paso a paso](#8-instalación-paso-a-paso)
9. [Operaciones](#9-operaciones)
10. [Procedimiento de rollback](#10-procedimiento-de-rollback)
11. [Monitoreo y logs](#11-monitoreo-y-logs)
12. [Consideraciones para producción](#12-consideraciones-para-producción)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Visión general

### ¿Qué hace?

El sistema pone en estado **idle** (réplicas = 0) los workloads (Deployments, DeploymentConfigs, StatefulSets) de uno o más proyectos OpenShift, usando el comando nativo `oc idle`. Antes de cada operación guarda un **snapshot de estado** con la cantidad de réplicas previas, permitiendo un **rollback** preciso a cualquier punto anterior.

### ¿Para qué sirve?

- Reducir consumo de recursos en horarios de baja demanda (noche, fines de semana)
- Gestionar ambientes no productivos (dev, staging, QA) de forma automatizada
- Complementar estrategias de ahorro de costo en clusters cloud

### Flujo de ejecución

```
CronJob (idle-ops)
  └── Pod con oc-idle-manager.sh
        ├── 1. Lee projects.txt desde ConfigMap
        ├── 2. Por cada proyecto:
        │     ├── Guarda snapshot de réplicas → PVC (/data/states/)
        │     └── Ejecuta `oc idle <servicio>` por cada servicio
        └── 3. Escribe log completo → PVC (/data/logs/)
```

### Flujo de rollback

```
Job ad-hoc (o CronJob con acción rollback)
  └── Pod con oc-idle-manager.sh rollback
        └── Por cada proyecto:
              ├── Lee el snapshot más reciente (o el indicado con --state-id)
              └── Ejecuta `oc scale --replicas=N` por cada workload
```

---

## 2. Estructura del repositorio

```
.
├── oc-idle-manager.sh              # Script principal de idle/rollback
│
├── idle-ops/                       # Infraestructura del proyecto idle-ops
│   ├── setup.yaml                  # Todos los recursos OCP (Namespace, SA, RBAC, PVC, CronJob)
│   ├── configmap.yaml              # ConfigMap con el script y projects.txt (alternativa a install.sh)
│   ├── rbac-per-namespace.yaml     # Alternativa least-privilege (RoleBinding por proyecto)
│   ├── rollback-job.yaml           # Template de Job para ejecutar rollbacks manuales
│   ├── debug-pvc.yaml              # Pod temporal para leer el contenido del PVC
│   ├── debug-job.yaml              # Job de diagnóstico con bash -x
│   ├── projects.txt                # Lista de proyectos a gestionar
│   └── install.sh                  # Script de instalación idempotente
│
└── demo-apps/                      # Aplicaciones de prueba
    ├── python-demo.yaml            # Proyecto python-demo (2 pods, Python 3.12)
    ├── node-demo.yaml              # Proyecto node-demo (3 pods, Node.js 20)
    ├── java-demo.yaml              # Proyecto java-demo (1 pod, Java 21)
    └── deploy-all.sh               # Despliega las tres apps de una vez
```

---

## 3. Prerequisitos

### Herramientas

| Herramienta | Versión mínima | Uso |
|---|---|---|
| `oc` | 4.18 | CLI de OpenShift |
| `bash` | 4.x | Ejecución del script localmente |

> En macOS el bash del sistema es 3.2 (incompatible con arrays). Instalar bash >= 4 via Homebrew: `brew install bash`

### Acceso al cluster

- Usuario con rol **cluster-admin** para aplicar `ClusterRole` y `ClusterRoleBinding`
- Acceso de lectura/escritura al proyecto `idle-ops`

### Cluster

- OpenShift 4.18+
- `UnidlingController` habilitado (activo por defecto en OCP 4.x)
- StorageClass disponible para el PVC (ReadWriteOnce)

---

## 4. Modelo RBAC — Opción A (ClusterRoleBinding)

### Configuración activa

El sistema utiliza **Opción A: ClusterRoleBinding**. Esta es la configuración desplegada en `setup.yaml`.

```
ServiceAccount: idle-manager (namespace: idle-ops)
        │
        └── ClusterRoleBinding: idle-manager
                │
                └── ClusterRole: idle-manager
                      └── Permisos sobre TODOS los namespaces del cluster
```

### ¿Por qué esta opción?

| Criterio | Opción A (activa) | Opción B (alternativa) |
|---|---|---|
| Tipo de binding | `ClusterRoleBinding` | `RoleBinding` por namespace |
| Alcance | Todos los namespaces | Solo los namespaces con RoleBinding |
| Gestión | Un solo recurso | Un RoleBinding por proyecto |
| Proyectos dinámicos | Sí, sin cambios de RBAC | No, requiere crear RoleBinding nuevo |
| Nivel de privilegio | Más amplio | Least-privilege |
| Recomendado para | Muchos proyectos / dinámicos | Proyectos fijos y auditados |

La Opción A fue elegida dado que la lista de proyectos es dinámica (se gestiona vía `projects.txt`) y no requiere intervención en el RBAC cada vez que se agrega un proyecto.

### Permisos otorgados

El `ClusterRole idle-manager` define exactamente los permisos que necesita `oc idle` y el rollback, sin privilegios innecesarios:

| API Group | Recursos | Verbos | Propósito |
|---|---|---|---|
| `""` (core) | `namespaces` | get, list | Validar que el proyecto existe |
| `project.openshift.io` | `projects` | get, list | Validar proyectos OCP |
| `""` (core) | `services` | get, list, watch, update, patch, **idle** | `oc idle` requiere el verbo `idle` (específico de OpenShift) además de los estándar de lectura/escritura |
| `""` (core) | `pods` | get, list | `oc idle` lee los pods para identificar el controlador (Deployment/RC) que respalda cada pod del Service; sin este permiso falla con `unable to find controller for pod` |
| `""` (core) | `endpoints` | get, list, watch, update, patch | `oc idle` lee los endpoints para descubrir los workloads que respaldan el Service |
| `discovery.k8s.io` | `endpointslices` | get, list, watch | En OCP 4.18+ `oc idle` consulta EndpointSlices; sin este permiso el comando falla silenciosamente |
| `""` (core) | `replicationcontrollers`, `replicationcontrollers/scale` | get, list, watch, update, patch | Backing de DeploymentConfigs |
| `apps` | `deployments`, `deployments/scale`, `replicasets`, `statefulsets`, `statefulsets/scale` | get, list, watch, update, patch | Guardar réplicas y escalar a 0 / rollback |
| `apps.openshift.io` | `deploymentconfigs`, `deploymentconfigs/scale` | get, list, watch, update, patch | Soporte para DCs nativos de OpenShift |

> **No se otorgan** permisos sobre: secrets, configmaps, roles, nodes, ni ningún otro recurso de infraestructura o seguridad.

### Alternativa para producción con auditoría estricta (Opción B)

Si se requiere least-privilege, reemplazar el `ClusterRoleBinding` de `setup.yaml` por `RoleBindings` individuales usando el archivo provisto:

```bash
# 1. Eliminar el ClusterRoleBinding existente
oc delete clusterrolebinding idle-manager

# 2. Crear RoleBindings por proyecto
oc apply -f idle-ops/rbac-per-namespace.yaml
```

Cada RoleBinding en `rbac-per-namespace.yaml` tiene la forma:

```yaml
kind: RoleBinding
metadata:
  name: idle-manager-from-idle-ops
  namespace: <proyecto-target>   # El SA de idle-ops actúa aquí
subjects:
  - kind: ServiceAccount
    name: idle-manager
    namespace: idle-ops          # El SA vive en idle-ops
roleRef:
  kind: ClusterRole
  name: idle-manager
```

Con esta opción, agregar un proyecto a `projects.txt` **requiere** también crear el RoleBinding correspondiente antes de la próxima ejecución del CronJob.

---

## 5. Recursos OpenShift en detalle

Todos los recursos del sistema están definidos en `idle-ops/setup.yaml` y se aplican con un solo comando.

### 5.1 Namespace `idle-ops`

```yaml
kind: Namespace
metadata:
  name: idle-ops
  labels:
    app.kubernetes.io/managed-by: idle-ops
```

Proyecto dedicado exclusivamente a la operación de idle. Aísla los recursos del sistema del resto de las cargas de trabajo del cluster.

### 5.2 ServiceAccount `idle-manager`

```yaml
kind: ServiceAccount
metadata:
  name: idle-manager
  namespace: idle-ops
```

Identidad bajo la cual se ejecuta el CronJob. Al correr dentro de un pod en OpenShift, el token de este SA se monta automáticamente en `/var/run/secrets/kubernetes.io/serviceaccount/token` y el CLI `oc` lo detecta sin necesidad de `oc login`.

### 5.3 ClusterRole `idle-manager`

Define el conjunto mínimo de permisos necesarios. Ver tabla completa en la [sección 4](#4-modelo-rbac--opción-a-clusterrolebinding).

### 5.4 ClusterRoleBinding `idle-manager`

Enlaza el `ClusterRole` con el `ServiceAccount`. Es el recurso que efectivamente otorga los permisos al SA en todos los namespaces del cluster.

### 5.5 PersistentVolumeClaim `idle-manager-data`

```yaml
kind: PersistentVolumeClaim
metadata:
  name: idle-manager-data
  namespace: idle-ops
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```

> ⚠️ **CRÍTICO para el funcionamiento del rollback.** Los pods de un CronJob son efímeros; sin este PVC, cada ejecución destruiría el historial de snapshots y el rollback sería imposible.

El PVC se monta en `/data` dentro del pod y contiene:

```
/data/
├── states/    # Snapshots de réplicas por proyecto y timestamp
│   ├── python-demo_20250101_200000.state
│   ├── node-demo_20250101_200000.state
│   └── java-demo_20250101_200000.state
└── logs/      # Log completo de cada ejecución
    ├── oc-idle-manager_20250101_200000.log
    └── oc-idle-manager_20250102_200000.log
```

### 5.6 ConfigMap `idle-manager-script`

No está en `setup.yaml` porque su contenido viene de archivos locales. Se crea con:

```bash
oc create configmap idle-manager-script \
    --from-file=oc-idle-manager.sh=oc-idle-manager.sh \
    --from-file=projects.txt=idle-ops/projects.txt \
    -n idle-ops \
    --dry-run=client -o yaml | oc apply -f -
```

Contiene dos claves:

| Clave | Origen | Descripción |
|---|---|---|
| `oc-idle-manager.sh` | `oc-idle-manager.sh` | Script principal ejecutado por el CronJob |
| `projects.txt` | `idle-ops/projects.txt` | Lista de proyectos a gestionar |

Se monta en `/scripts/` con permisos `0555` (ejecutable por todos los usuarios).

### 5.7 CronJob `idle-manager`

```yaml
spec:
  schedule: "0 20 * * 1-5"
  timeZone: "America/Argentina/Buenos_Aires"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 5
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 3600
      ttlSecondsAfterFinished: 86400
```

| Parámetro | Valor | Razón |
|---|---|---|
| `schedule` | `0 20 * * 1-5` | Lunes a viernes a las 20:00 (hora Argentina) |
| `timeZone` | `America/Argentina/Buenos_Aires` | Evita ambigüedades con UTC en el cluster |
| `concurrencyPolicy: Forbid` | — | Previene ejecuciones superpuestas si un Job tarda más de lo esperado |
| `backoffLimit: 0` | — | Sin reintentos automáticos; el script gestiona sus propios errores internamente |
| `successfulJobsHistoryLimit: 5` | — | Conserva los últimos 5 Jobs exitosos para auditoría |
| `failedJobsHistoryLimit: 5` | — | Conserva los últimos 5 Jobs fallidos para diagnóstico |
| `activeDeadlineSeconds` | `3600` | Timeout máximo del Job: si el script no termina en 1 hora, Kubernetes mata el pod y marca el Job como fallido; evita ejecuciones colgadas que bloquean el schedule siguiente |
| `ttlSecondsAfterFinished` | `86400` | El pod persiste 24 horas después de terminar (éxito o fallo); permite leer logs aunque CRI-O haya limpiado el contenedor internamente |

#### Imagen del contenedor

```
image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
```

ImageStream interno del cluster (`openshift/cli`). Multi-arch (amd64, arm64, s390x, ppc64le), siempre compatible con la versión del cluster y no requiere pull secret externo.

> **Alternativas:**
> - `registry.redhat.io/openshift4/ose-cli-rhel9:v4.18` — imagen oficial Red Hat, recomendada para producción (requiere pull secret)
> - `quay.io/openshift/origin-cli:4.18` — imagen pública, solo amd64

#### Security Context

El pod está configurado para cumplir con el SCC `restricted-v2` de OCP 4.11+:

```yaml
# Pod level
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault

# Container level
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
```

---

## 6. El script oc-idle-manager.sh

### Acciones disponibles

#### `idle` — Poner en idle

1. Valida que el proyecto existe
2. **Guarda snapshot de estado** (réplicas actuales de Deployments, DCs y StatefulSets) en `$OC_IDLE_STATE_DIR/<proyecto>_<TIMESTAMP>.state`
3. Lista todos los Services del namespace (o usa la lista provista con `-s`)
4. Ejecuta `oc idle -n <proyecto> <servicio>` por cada Service
5. Registra resultado en el log

#### `rollback` — Restaurar estado previo

1. Valida que el proyecto existe
2. Localiza el snapshot más reciente (o el indicado con `--state-id`)
3. Ejecuta `oc scale --replicas=N` por cada workload registrado en el snapshot
4. Registra resultado en el log

### Opciones

```
idle / rollback

  -p, --project  <name>    Un proyecto
  -P, --projects <list>    Lista separada por comas
  -f, --file     <path>    Archivo con un proyecto por línea (soporta comentarios #)
  -s, --services <list>    Servicios específicos (default: todos)
      --state-id <id>      ID de snapshot para rollback (default: el más reciente)
  -d, --dry-run            Muestra las acciones sin ejecutarlas
  -h, --help               Ayuda
```

### Variables de entorno

| Variable | Default | Descripción |
|---|---|---|
| `OC_IDLE_STATE_DIR` | `~/.oc-idle-manager/states` | Directorio de snapshots de estado |
| `OC_IDLE_LOG_DIR` | `~/.oc-idle-manager/logs` | Directorio de logs |

En el CronJob estas variables apuntan a subdirectorios del PVC (`/data/states`, `/data/logs`).

### Formato del snapshot de estado

```
# oc-idle-manager state snapshot
# project:   python-demo
# timestamp: 20250101_200000
# saved_at:  2025-01-01T20:00:00+00:00
#
# format: <kind> <name> <replicas>

deploy python-app 2
```

| Campo | Valores posibles | Descripción |
|---|---|---|
| `kind` | `deploy`, `dc`, `sts` | Tipo de workload |
| `name` | string | Nombre del recurso |
| `replicas` | entero >= 0 | Réplicas al momento del snapshot |

### Detección de entorno in-cluster

Al ejecutarse dentro de un pod, el script detecta automáticamente el token del ServiceAccount:

```
[INFO ] In-cluster mode | namespace: idle-ops
[INFO ] Authenticated as: system:serviceaccount:idle-ops:idle-manager | Server: https://...
```

No se requiere `oc login` en el CronJob.

---

## 7. Aplicaciones demo

Tres proyectos de prueba para validar el sistema. Cada uno incluye: `Namespace`, `ConfigMap` con el código fuente, `Deployment`, `Service` (ClusterIP) y `Route` (TLS edge).

| Proyecto | App | Réplicas | Puerto | Imagen | Código |
|---|---|---|---|---|---|
| `python-demo` | `python-app` | 2 | 8080 | `python:3.12-slim` | stdlib `http.server` |
| `node-demo` | `node-app` | 3 | 3000 | `node:20-slim` | stdlib `http` module |
| `java-demo` | `java-app` | 1 | 8080 | `eclipse-temurin:21-jre-alpine` | `com.sun.net.httpserver` |

Todos los proyectos llevan el label `idle-ops/managed: "true"` para identificación.

### Estrategia Java (sin imagen custom)

Java requiere compilación. Se resuelve con un `initContainer`:

```
initContainer: eclipse-temurin:21-jdk-alpine
  └── Compila HelloServer.java (ConfigMap /src) → emptyDir /compiled

Main container: eclipse-temurin:21-jre-alpine
  └── java -cp /compiled HelloServer
```

No requiere pipeline de CI/CD, registro privado ni Dockerfile.

### Respuesta de las APIs

Todas responden con JSON en cualquier ruta:

```json
{
  "app": "python-demo",
  "version": "1.0.0",
  "language": "Python 3.12.x",
  "message": "Hola desde Python!",
  "hostname": "python-app-7d9f8c-xkp2n",
  "path": "/"
}
```

---

## 8. Instalación paso a paso

### Paso 1 — Clonar y verificar prerrequisitos

```bash
# Verificar versión de oc
oc version

# Verificar autenticación y permisos
oc whoami
oc auth can-i create clusterrole --all-namespaces   # debe responder "yes"
```

### Paso 2 — Configurar la lista de proyectos

Editar `idle-ops/projects.txt` con los proyectos a gestionar:

```bash
vim idle-ops/projects.txt
```

```
# Un proyecto por línea. Las líneas con # se ignoran.
python-demo
node-demo
java-demo
```

### Paso 3 — (Opcional) Desplegar las aplicaciones demo

```bash
./demo-apps/deploy-all.sh
```

Este script también agrega los tres proyectos demo al `projects.txt` automáticamente.

### Paso 4 — Desplegar la infraestructura de idle-ops

```bash
./idle-ops/install.sh
```

El script realiza las siguientes acciones en orden:

1. Aplica `idle-ops/setup.yaml` (Namespace, ServiceAccount, ClusterRole, ClusterRoleBinding, PVC, CronJob)
2. Crea o actualiza el ConfigMap `idle-manager-script` con el script y el `projects.txt`
3. Muestra un resumen del estado final en el cluster

### Paso 5 — Verificar el despliegue

```bash
# Ver todos los recursos de idle-ops
oc get all,pvc,configmap,clusterrole,clusterrolebinding \
    -n idle-ops \
    -l app.kubernetes.io/name=idle-manager

# Verificar que el ServiceAccount tiene los permisos correctos
oc auth can-i idle services \
    --as=system:serviceaccount:idle-ops:idle-manager \
    -n python-demo

# Verificar que el CronJob está configurado
oc describe cronjob idle-manager -n idle-ops
```

### Paso 6 — Ejecutar un dry-run manual

Antes de la primera ejecución automática, validar con dry-run:

```bash
oc create job idle-dryrun-$(date +%s) \
    --from=cronjob/idle-manager \
    -n idle-ops

# Editar el Job recién creado para agregar --dry-run a los args
oc edit job idle-dryrun-<timestamp> -n idle-ops
# Cambiar: args: ["idle", "-f", "/scripts/projects.txt"]
# Por:     args: ["idle", "-f", "/scripts/projects.txt", "--dry-run"]
```

Verificar los logs:

```bash
oc logs -l job-name=idle-dryrun-<timestamp> -n idle-ops
```

---

## 9. Operaciones

### Ejecución automática

El CronJob se ejecuta automáticamente según el schedule configurado (`0 20 * * 1-5`). No requiere intervención manual.

### Ejecutar idle manualmente

```bash
# Sobre todos los proyectos del archivo
oc create job idle-manual-$(date +%s) \
    --from=cronjob/idle-manager \
    -n idle-ops

# Sobre un proyecto específico (crear Job con args personalizados)
oc create job idle-single-$(date +%s) -n idle-ops \
    --image=quay.io/openshift/origin-cli:4.18 \
    -- /bin/bash /scripts/oc-idle-manager.sh idle -p python-demo
```

### Ejecutar rollback

Ver el [Procedimiento de rollback](#10-procedimiento-de-rollback) para la guía paso a paso completa.

### Actualizar la lista de proyectos

```bash
# 1. Editar el archivo
vim idle-ops/projects.txt

# 2. Actualizar el ConfigMap (idempotente)
oc create configmap idle-manager-script \
    --from-file=oc-idle-manager.sh=oc-idle-manager.sh \
    --from-file=projects.txt=idle-ops/projects.txt \
    -n idle-ops \
    --dry-run=client -o yaml | oc apply -f -
```

El cambio tiene efecto en la próxima ejecución del CronJob.

### Suspender el CronJob temporalmente

```bash
# Suspender
oc patch cronjob idle-manager -n idle-ops \
    -p '{"spec":{"suspend":true}}'

# Reactivar
oc patch cronjob idle-manager -n idle-ops \
    -p '{"spec":{"suspend":false}}'
```

---

## 10. Procedimiento de rollback

El rollback restaura los workloads de uno o más proyectos a la cantidad de réplicas que tenían justo antes del último `idle`. El script lee el snapshot de estado guardado en el PVC y ejecuta `oc scale` por cada recurso registrado.

> **Prerequisito:** debe existir al menos un snapshot en el PVC para cada proyecto a restaurar. Los snapshots se crean automáticamente al inicio de cada ejecución de `idle`. Sin snapshot no hay rollback posible.

### Paso 1 — Verificar snapshots disponibles

Antes de iniciar un rollback, confirmar qué snapshots existen en el PVC:

```bash
oc apply -f debug-pvc.yaml
oc logs pod/pvc-check -n idle-ops -f
oc delete pod/pvc-check -n idle-ops
```

La sección `=== /data/states ===` muestra los archivos disponibles:

```
python-demo_20260920_200021.state
node-demo_20260920_200021.state
java-demo_20260920_200021.state
```

El formato del nombre es `<proyecto>_<YYYYMMDD_HHMMSS>.state`. El timestamp identifica el momento en que se ejecutó el idle.

### Paso 2 — Editar rollback-job.yaml

El archivo `idle-ops/rollback-job.yaml` es el template para ejecutar rollbacks. Editar los `args` según el caso:

#### Caso A — Rollback de todos los proyectos (último snapshot de cada uno)

```yaml
args:
  - "rollback"
  - "-f"
  - "/scripts/projects.txt"
```

#### Caso B — Rollback de un proyecto específico

```yaml
args:
  - "rollback"
  - "-p"
  - "python-demo"
```

#### Caso C — Rollback de varios proyectos específicos

```yaml
args:
  - "rollback"
  - "-P"
  - "python-demo,node-demo"
```

#### Caso D — Rollback a un snapshot específico (no el más reciente)

```yaml
args:
  - "rollback"
  - "-p"
  - "python-demo"
  - "--state-id"
  - "20260920_200021"
```

El `--state-id` es el timestamp del archivo `.state` visto en el Paso 1.

#### Caso E — Dry-run (verificar sin aplicar cambios)

Agregar `--dry-run` a cualquiera de los casos anteriores:

```yaml
args:
  - "rollback"
  - "-f"
  - "/scripts/projects.txt"
  - "--dry-run"
```

### Paso 3 — Ejecutar el rollback

```bash
# Eliminar el Job anterior si existe (el pod template es inmutable)
oc delete job/idle-rollback -n idle-ops --ignore-not-found

oc apply -f rollback-job.yaml
```

### Paso 4 — Seguir los logs en tiempo real

```bash
oc logs job/idle-rollback -n idle-ops -f
```

Salida esperada:

```
[2026-09-20 20:15:03] [===  ] --- oc-idle-manager start ---
[2026-09-20 20:15:03] [INFO ] Action:    rollback
[2026-09-20 20:15:03] [INFO ] Projects:  python-demo node-demo java-demo
[2026-09-20 20:15:04] [===  ] --- Rolling back project: python-demo ---
[2026-09-20 20:15:04] [INFO ] [python-demo] Using state snapshot: /data/states/python-demo_20260920_200021.state
[2026-09-20 20:15:04] [INFO ] [python-demo] Scaling deployment/python-app to 2 replica(s)
[2026-09-20 20:15:05] [OK   ] [python-demo] deployment/python-app scaled to 2
[2026-09-20 20:15:05] [OK   ] [python-demo] Rollback completed successfully
...
[2026-09-20 20:15:08] [===  ] --- Summary ---
[2026-09-20 20:15:08] [INFO ] Total projects processed: 3
[2026-09-20 20:15:08] [OK   ] Succeeded: 3
```

### Paso 5 — Verificar que los pods levantaron

```bash
oc get pods -n python-demo
oc get pods -n node-demo
oc get pods -n java-demo
```

### Paso 6 — Limpiar el Job

```bash
oc delete job/idle-rollback -n idle-ops
```

> **Nota:** si se necesita ejecutar otro rollback, eliminar el Job primero. `rollback-job.yaml` siempre crea un Job con el mismo nombre `idle-rollback`. Alternativamente, editar `metadata.name` con un nombre único por ejecución.

---

## 11. Monitoreo y logs


### Ver logs de la última ejecución

```bash
# Logs del pod más reciente
oc logs -l app.kubernetes.io/name=idle-manager \
    -n idle-ops \
    --tail=100

# Logs de un Job específico
oc logs job/idle-manager-<timestamp> -n idle-ops
```

### Ver historial de Jobs

```bash
oc get jobs -n idle-ops --sort-by=.metadata.creationTimestamp
```

### Acceder a los logs persistidos en el PVC

```bash
# Lanzar un pod temporal que monte el PVC
oc run pvc-browser \
    --image=busybox \
    --restart=Never \
    --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"idle-manager-data"}}],"containers":[{"name":"pvc-browser","image":"busybox","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"data","mountPath":"/data"}]}]}}' \
    -n idle-ops -it

# Dentro del pod:
ls /data/logs/
cat /data/logs/oc-idle-manager_20250101_200000.log
ls /data/states/

# Salir y limpiar
exit
oc delete pod pvc-browser -n idle-ops
```

### Alertas recomendadas (producción)

Configurar alertas en el stack de monitoreo del cluster para:

| Condición | Severidad |
|---|---|
| Job del CronJob en estado `Failed` | Warning |
| CronJob sin ejecuciones en las últimas 25 horas | Warning |
| PVC con uso > 80% | Info |

---

## 12. Consideraciones para producción

### RBAC

- **Evaluar migración a Opción B** (RoleBindings por namespace) si el ambiente requiere auditoría estricta de accesos.
- Revisar periódicamente que el `ClusterRole` no tenga permisos en exceso respecto a los necesarios.
- Usar `oc auth can-i` para verificar permisos antes de cualquier despliegue.

### Imagen del contenedor

- Reemplazar `quay.io/openshift/origin-cli:4.18` por la imagen oficial Red Hat:
  ```
  registry.redhat.io/openshift4/ose-cli-rhel9:v4.18
  ```
  Esto garantiza soporte, parches de seguridad y compatibilidad certificada con OCP 4.18.
- Configurar un pull secret para `registry.redhat.io` en el namespace `idle-ops`.
- Fijar la imagen a un digest específico en lugar de un tag mutable:
  ```yaml
  image: registry.redhat.io/openshift4/ose-cli-rhel9@sha256:<digest>
  ```

### PVC y retención de datos

- Verificar que la `StorageClass` usada soporte snapshots o backups si se requiere recuperación ante desastres.
- Implementar una política de retención para los archivos `.state` y `.log` más antiguos. Los logs del CronJob también quedan en el PVC y crecen con el tiempo.
- Considerar ajustar el storage del PVC según la cantidad de proyectos y la frecuencia de ejecución.

### Schedule y timezone

- El campo `timeZone` del CronJob requiere OCP 4.11+. Verificar soporte.
- Coordinar el horario con los equipos de aplicaciones antes de activar en producción para evitar afectar cargas de trabajo críticas.
- Considerar ventanas de mantenimiento existentes y no superponer con backups u otras automatizaciones.

### Seguridad del script

- El ConfigMap con el script puede ser modificado por cualquier usuario con permisos de `update` sobre ConfigMaps en `idle-ops`. Restringir el acceso al namespace `idle-ops` a operadores autorizados.
- El script no maneja secretos ni credenciales; usa exclusivamente el token del ServiceAccount.

### Dry-run antes de producción

- Siempre ejecutar con `--dry-run` la primera vez en un ambiente nuevo.
- Mantener los Jobs de dry-run en el historial para auditoría.

### Notificaciones

- Integrar alertas de Jobs fallidos con el sistema de notificaciones del equipo (Slack, PagerDuty, etc.) usando el stack de alertas de OCP (Alertmanager).

---

## 13. Troubleshooting

### El CronJob no se ejecuta

```bash
# Verificar que no está suspendido
oc get cronjob idle-manager -n idle-ops -o jsonpath='{.spec.suspend}'

# Verificar eventos
oc describe cronjob idle-manager -n idle-ops
```

### El Job falla: `condition: Failed`

El evento `SawCompletedJob condition: Failed` en el CronJob indica que el pod se creó y ejecutó, pero el script terminó con código no-zero. No es un error de creación del pod.

```bash
# Ver el pod del Job fallido (disponible hasta 24h después gracias a ttlSecondsAfterFinished)
oc get pods -n idle-ops --sort-by=.metadata.creationTimestamp

# Leer los logs del pod
oc logs <pod-name> -n idle-ops

# Describir el Job específico para ver eventos y estado
oc describe job idle-manager-<id> -n idle-ops
```

Causas más comunes:
- El proyecto listado en `projects.txt` no existe en el cluster (`oc get project <nombre>`)
- El ServiceAccount no tiene el verbo `idle` sobre services (ver sección siguiente)
- `oc idle` no encuentra endpoints activos en el namespace

### Los logs no están disponibles (`unable to retrieve container logs for cri-o://...`)

CRI-O eliminó los archivos de log del contenedor antes de que pudieran ser leídos. Esto ocurre cuando `ttlSecondsAfterFinished` no estaba configurado o el pod fue eliminado muy rápido.

```bash
# Verificar que el CronJob tiene ttlSecondsAfterFinished configurado
oc get cronjob idle-manager -n idle-ops \
    -o jsonpath='{.spec.jobTemplate.spec.ttlSecondsAfterFinished}'
# Debe devolver: 86400

# Si no está configurado, reaplicar setup.yaml
oc apply -f idle-ops/setup.yaml

# Los logs persistidos en el PVC siguen disponibles aunque el pod ya no exista
oc run pvc-browser --image=busybox --restart=Never \
    --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"idle-manager-data"}}],"containers":[{"name":"pvc-browser","image":"busybox","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"data","mountPath":"/data"}]}]}}' \
    -n idle-ops -it
# Dentro del pod: cat /data/logs/oc-idle-manager_<timestamp>.log
```

### El Job falla con `Forbidden`

El ServiceAccount no tiene permisos sobre el namespace target.

```bash
# Verificar el permiso crítico: el verbo "idle" sobre services
oc auth can-i idle services \
    --as=system:serviceaccount:idle-ops:idle-manager \
    -n <proyecto-target>

# Ver todos los verbos disponibles para el SA sobre services
oc policy who-can idle services -n <proyecto-target>

# Si usa Opción A, verificar que el ClusterRoleBinding existe
oc get clusterrolebinding idle-manager

# Si usa Opción B, verificar que el RoleBinding existe en el target
oc get rolebinding idle-manager-from-idle-ops -n <proyecto-target>
```

### `oc idle` no escala el workload a 0

`oc idle` requiere que el Service tenga Endpoints activos (al menos un pod running). Si el Deployment ya tiene 0 réplicas, `oc idle` no hace nada. Verificar el estado antes de ejecutar.

```bash
oc get endpoints -n <proyecto>
```

### No hay snapshot disponible para rollback

Si el pod murió antes de guardar el snapshot, o el PVC fue recreado:

```bash
# Listar archivos en el PVC
oc exec ... -- ls /data/states/

# Alternativa: restaurar manualmente con oc scale
oc scale deployment/<nombre> --replicas=<N> -n <proyecto>
```

### El PVC no se puede montar (`ReadWriteOnce`)

`ReadWriteOnce` permite que solo un nodo monte el PVC a la vez. Si hay un Job anterior cuyo pod no terminó de liberar el volumen:

```bash
# Verificar pods que usan el PVC
oc get pods -n idle-ops -o wide | grep idle-manager

# Eliminar pods colgados si es necesario
oc delete pod <pod-name> -n idle-ops
```
