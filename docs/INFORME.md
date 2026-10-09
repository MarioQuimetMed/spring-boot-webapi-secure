# Informe final — Pipeline CI/CD DevSecOps con DefectDojo

> Borrador. Completar los campos marcados con **[COMPLETAR]** y adjuntar las capturas
> indicadas con **📷**. No incluir contraseñas, tokens (PAT, API key de DefectDojo) ni secretos.

## 1. Datos generales

| Campo | Valor |
|---|---|
| Integrantes | **[COMPLETAR]** |
| Repositorio | https://github.com/MarioQuimetMed/spring-boot-webapi-secure |
| Repositorio base | https://github.com/pablovillazon/spring-boot-webapi-secure |
| Rama de trabajo | `feature/add-to-deploy-image-docker` (PR #3 → `main`) |
| Imagen publicada | `ghcr.io/marioquimetmed/spring-boot-webapi-secure` |

## 2. Threat Modeling

### 2.1 Análisis de la primera semana
**[COMPLETAR: pegar el Threat Modeling entregado en la semana 1 (diagrama, activos, amenazas STRIDE, mitigaciones).]**

### 2.2 Ajustes por la implementación final
La implementación agrega componentes que no formaban parte de la arquitectura original:

| Componente nuevo | Amenaza relevante | Control aplicado / pendiente |
|---|---|---|
| Runners de GitHub Actions | Ejecución de código no confiable en el pipeline; acciones de terceros (supply chain) | Permisos mínimos por job (`contents: read`); acciones fijadas por tag mayor (**mejora:** fijar por SHA) |
| Imágenes de herramientas (`semgrep/semgrep`, `aquasec/trivy:0.74.0`, `openpolicyagent/conftest:v0.71.1`) | Imagen de herramienta comprometida o cambiante | Trivy y Conftest con versión fija; **pendiente:** fijar Semgrep por versión/digest |
| `GITHUB_TOKEN` con `packages: write` | Abuso del token para publicar imágenes no autorizadas | Permiso concedido solo al job `image-scan`/`image-build-scan-push`; en PR la imagen no se publica |
| Registro GHCR | Imagen manipulada o desplegar una versión no escaneada | Se publica **la misma imagen** que escaneó Trivy, etiquetada `sha-<commit>` y con label `org.opencontainers.image.revision` |
| Paquete GHCR público (hereda visibilidad del repo) | Cualquiera puede descargar una app deliberadamente vulnerable | Riesgo aceptado por ser un laboratorio; en un proyecto real el paquete sería privado |
| Ruleset + Quality Gate | Código con hallazgos críticos llega a `main` | El Quality Gate falla ante HIGH/CRITICAL y el ruleset bloquea el merge |
| Host Docker local (despliegue) | Exposición de la app vulnerable en la red | Puerto publicado solo en `localhost:8081`; ejecutar en red aislada |
| Instancia DefectDojo (`localhost:8080`) | Fuga de información de vulnerabilidades; credenciales de admin | Instancia local, contraseña de admin generada por el initializer, no se publica |

## 3. Pipeline CI/CD

### 3.1 Workflows

| Workflow | Disparador | Jobs |
|---|---|---|
| [ci-sec.yml](../.github/workflows/ci-sec.yml) — CI | `push` a `feature/**`, `bugfix/**`, `hotfix/**`; `pull_request` a `main`/`develop` | Build & Test → SAST CodeQL → SAST Semgrep → SpotBugs/PMD → Image Scan Trivy (+ publicación en GHCR si es `push`) → Policy as Code Conftest → **Quality Gate** |
| [ci-cd-sec.yml](../.github/workflows/ci-cd-sec.yml) — CI/CD | `push` a `main`/`develop` | Mismos controles + Image Build, Scan & Push a GHCR + Quality Gate |
| [nightly-sca.yml](../.github/workflows/nightly-sca.yml) — Nightly | `cron` diario 00:55 UTC (20:55 Bolivia) y `workflow_dispatch` | Build, CodeQL, Semgrep, **SCA OWASP Dependency-Check**, SpotBugs/PMD, Quality Gate |
| [security-semgrep.yml](../.github/workflows/security-semgrep.yml) | `workflow_call` (reutilizable) | Semgrep con `--config auto` + reglas propias [.semgrep.yml](../.semgrep.yml) |
| [security-trivy.yml](../.github/workflows/security-trivy.yml) | `workflow_call` (reutilizable) | Construye la imagen **del proyecto** ([Dockerfile](../Dockerfile)), la escanea y opcionalmente la publica |

### 3.2 Quality Gate
[.github/scripts/quality-gate.sh](../.github/scripts/quality-gate.sh) descarga todos los artifacts y falla si:
- algún job terminó en `failure`, o falta / no se puede leer un reporte;
- Semgrep tiene resultados `ERROR`; SpotBugs rank 1–9; CodeQL `security-severity ≥ 7`;
  Trivy o Dependency-Check `HIGH`/`CRITICAL`; Conftest tiene reglas `deny` incumplidas.

Los escáneres no usan `--exit-code`: siempre generan y publican su reporte (`if: always()`),
y la decisión de bloqueo la toma el Quality Gate. Así los reportes se conservan aunque el pipeline se bloquee.

Como la aplicación es **deliberadamente vulnerable**, el Quality Gate falla en todas las
ejecuciones y el ruleset impide el merge del PR a `main`: es la evidencia de que el control funciona.

### 3.3 CD local
1. Cada `push` a la rama construye la imagen, la escanea con Trivy y publica **esa misma imagen** en GHCR con los tags `sha-<commit>` y `<rama>` (con `/` reemplazada por `-`).
2. El despliegue se inicia manualmente con [docker-compose.yml](../docker-compose.yml) (`pull_policy: always`):

```powershell
docker compose up -d                            # ultima imagen de la rama
$env:TAG="sha-d88c510"; docker compose up -d    # version de un commit concreto
docker compose ps                               # STATUS -> (healthy)
curl.exe http://localhost:8081/actuator/health
docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' webapi
```

El último comando devuelve el commit desde el que se construyó la imagen (trazabilidad commit → imagen → contenedor).
El paquete hereda la visibilidad pública del repositorio, por lo que no requiere `docker login`.

📷 `docker compose ps` en estado *healthy*, respuesta del health check, página del paquete en GitHub.

## 4. Herramientas, controles y reportes

| Control | Herramienta | Condición | Reporte JSON (artifact) | Parser DefectDojo |
|---|---|---|---|---|
| SAST | Semgrep | Obligatorio | `semgrep-reports/semgrep-results.json` (`--json-output`) | Semgrep JSON Report |
| SAST (complementario) | CodeQL | Extra | `codeql-sarif/java.sarif` | SARIF |
| SAST (complementario) | SpotBugs / PMD | Extra | `static-analysis-reports/spotbugsXml.xml` | SpotBugs Scan |
| Análisis de imagen | Trivy 0.74.0 | Obligatorio | `trivy-report/trivy-report.json` (`--format json --output`) | Trivy Scan |
| SCA | OWASP Dependency-Check | Opcional | `dependency-check-report/dependency-check-report.json` (+ `.xml`) | Dependency Check Scan (usa el **XML**) |
| Policy as Code | Conftest + [policy/dockerfile.rego](../policy/dockerfile.rego) | Opcional | `conftest-report/conftest-report.json` (`--output json`) | **Sin parser** (ver 6.3) |

Reglas de la política Rego sobre el Dockerfile: imágenes base con tag fijo y sin `latest`, runtime sin JDK completo,
`USER` no root en la etapa final y `HEALTHCHECK` (warn).

## 5. Evidencias de ejecución

| Evidencia | Commit | Ejecución (push) | Ejecución (PR) | Resultado |
|---|---|---|---|---|
| Línea base anterior | `191b317` | — | [37664775503](https://github.com/MarioQuimetMed/spring-boot-webapi-secure/actions/runs/37664775503) | Todos los jobs ✅, Quality Gate ❌ |
| **Antes** (publicación GHCR) | `0076bfd` | [37981088344](https://github.com/MarioQuimetMed/spring-boot-webapi-secure/actions/runs/37981088344) | [37981092700](https://github.com/MarioQuimetMed/spring-boot-webapi-secure/actions/runs/37981092700) | Todos los jobs ✅, imagen `sha-0076bfd` publicada, Quality Gate ❌ |
| **Después** (correcciones) | `d88c510` | [37981713053](https://github.com/MarioQuimetMed/spring-boot-webapi-secure/actions/runs/37981713053) | [37981718135](https://github.com/MarioQuimetMed/spring-boot-webapi-secure/actions/runs/37981718135) | Todos los jobs ✅, imagen `sha-d88c510` publicada, Quality Gate ❌ |
| SCA (Nightly manual) | **[COMPLETAR]** | **[COMPLETAR]** | — | **[COMPLETAR]** |

Resumen del Quality Gate (hallazgos que bloquean):

| Control | Antes (`0076bfd`) | Después (`d88c510`) |
|---|---|---|
| Semgrep (`ERROR`) | 7 | 7 |
| CodeQL (`security-severity ≥ 7`) | 4 | 4 (`java/sql-injection` 8.8, `java/spring-disabled-csrf-protection` 8.8, `java/xss` 7.8, `java/sensitive-log` 7.5) |
| Trivy (`HIGH`/`CRITICAL`) | 25 (9 C / 16 H) | 24 (8 C / 16 H) |
| Conftest (`deny`) | 1 | **0** |
| Tamaño de imagen | 613 MB | 347 MB |

📷 Grafo del workflow, Summary del Quality Gate, lista de artifacts de cada ejecución.

## 6. Gestión de hallazgos en DefectDojo

### 6.1 Organización
- **Product Type:** **[COMPLETAR, p. ej. "Diplomado DevSecOps"]**
- **Product:** `spring-boot-webapi-secure`
- **Engagement** (tipo CI/CD): `Pipeline 0076bfd (antes)` — Build ID `37981088344`, commit `0076bfd`, rama `feature/add-to-deploy-image-docker`, URL del repositorio.
- **Tests:** uno por reporte importado (Semgrep, Trivy, CodeQL/SARIF, SpotBugs, Dependency-Check).
- **Antes/después:** el Test de Trivy se re-importó (*Re-Import Scan Results*) con el reporte de `d88c510`; DefectDojo cerró como *Mitigated* el hallazgo CVE-2022-42889.

📷 Vista del Product, del Engagement con sus Tests y del Test de Trivy tras el re-import.

### 6.2 Clasificación (triage)

| Categoría | Marcado en DefectDojo | Hallazgos |
|---|---|---|
| **Confirmados** | `Active` + `Verified` | SQL Injection `ProductController.java:24`; XSS `CommentController.java:19`; secretos en código `AuthController.java:18-19`; contraseña en logs `AuthController.java:26`; `permitAll()` y CSRF deshabilitado `SecurityConfig.java:15-16`; CVE-2022-42889 (corregido) |
| **Pendientes de investigación** | `Active`, sin `Verified`, con nota | CVE de Tomcat, Spring Framework, Jackson y Micrometer (requieren analizar si la app usa la funcionalidad afectada, p. ej. HTTP/2 de Tomcat) **[COMPLETAR según revisión]** |
| **Posibles falsos positivos / duplicados** | `False Positive` o `Duplicate` con nota | La misma SQLi es reportada por 3 reglas de Semgrep (`lab-java-sql-concatenation`, `tainted-sql-string`, `spring-sqli`) y por CodeQL; el XSS por 2 reglas de Semgrep. Se conserva uno por vulnerabilidad **[COMPLETAR con IDs]** |

Prioridad: se priorizan los hallazgos **explotables remotamente sin autenticación** (todos los endpoints son
`permitAll`), por lo que SQLi y XSS van primero; luego las dependencias con CVE críticos y fix disponible;
por último los hallazgos de configuración y logging.

📷 Lista de findings filtrada por estado y detalle de un hallazgo de cada categoría.

### 6.3 Limitación: Conftest
DefectDojo no tiene un parser para la salida JSON de Conftest. El reporte
`conftest-report.json` se adjunta como anexo y su resultado se documenta aquí:
antes `1 failure` (*"La imagen de runtime 'eclipse-temurin:21-jdk-alpine' incluye el JDK completo"*), después `0 failures`.

## 7. Análisis de hallazgos relevantes

### Hallazgo 1 — Text4Shell en commons-text (CVE-2022-42889) ✅ corregido
- **Evidencia:** Trivy (`trivy-report.json`, target `Java`) reporta `org.apache.commons:commons-text 1.9`, severidad CRITICAL, versión corregida `1.10.0`. También lo reporta Dependency-Check.
- **Componente afectado:** [pom.xml](../pom.xml), dependencia `commons-text`, empaquetada en el fat JAR de la imagen.
- **Riesgo:** ejecución remota de código mediante interpolación de variables (`${script:...}`) si una entrada del usuario llega a `StringSubstitutor`. Hoy el código no la usa, pero la librería vulnerable viaja en la imagen y cualquier uso futuro sería explotable.
- **Acción:** actualizar a `1.15.0` (la más reciente). Es la acción más barata: no hay cambios de API para el proyecto.
- **Verificación:** Trivy del commit `d88c510` ya no contiene CVE-2022-42889. Trivy pasa de 9 a 8 CRITICAL, Build & Test sigue en verde y en DefectDojo el re-import lo marca *Mitigated*.

### Hallazgo 2 — Imagen de runtime con JDK completo ✅ corregido
- **Evidencia:** Conftest, regla `deny` de [policy/dockerfile.rego](../policy/dockerfile.rego): *"La imagen de runtime 'eclipse-temurin:21-jdk-alpine' incluye el JDK completo; usar una imagen JRE"*.
- **Componente afectado:** [Dockerfile](../Dockerfile), etapa final (`FROM`).
- **Riesgo:** el runtime incluía compilador y herramientas del JDK (`javac`, `jshell`, `jcmd`...) que un atacante con ejecución en el contenedor podría aprovechar; mayor superficie de ataque y tamaño.
- **Acción:** cambiar a `eclipse-temurin:21-jre-alpine`.
- **Verificación:** Conftest pasa de 1 a 0 fallas y la imagen de 613 MB a 347 MB (−43%). El conteo de CVE de Trivy no cambia: los CVE restantes vienen de las librerías Java, no de la imagen base. La aplicación arranca en estado *healthy* con `docker compose up -d`.

### Hallazgo 3 — SQL Injection en búsqueda de productos ⚠️ confirmado, no corregido
- **Evidencia:** Semgrep (`lab-java-sql-concatenation`, `tainted-sql-string`, `spring-sqli`) y CodeQL (`java/sql-injection`, security-severity 8.8, `ProductController.java:25`).
- **Componente afectado:** [ProductController.java:24](../src/main/java/bo/edu/devsecops/controller/ProductController.java#L24): `"... WHERE name LIKE '%" + name + "%'"` con `name` tomado de `@RequestParam`.
- **Riesgo:** CRÍTICO. El endpoint es público (`permitAll`) y permite leer o modificar toda la base (incluida la tabla `users`). Por ejemplo, `?name=' UNION SELECT id, username, email FROM users --` .
- **Acción propuesta:** consulta parametrizada, igual que en `AdminController`:
  ```java
  return jdbcTemplate.queryForList(
      "SELECT id, name, price FROM products WHERE name LIKE ?", "%" + name + "%");
  ```
  No se aplicó porque la vulnerabilidad es parte del laboratorio. En DefectDojo se registró como confirmada, con la acción de tratamiento en una nota (o *Risk Accepted*, por ser intencional).
- **Verificación:** las 3 reglas de Semgrep y la de CodeQL dejan de reportar el archivo. Además, el payload de inyección devuelve una lista vacía en lugar de los datos de `users`.

## 8. Conclusiones y mejoras propuestas

**Conclusiones**
- El pipeline aplica SAST, análisis de imagen, SCA y Policy as Code como pasos identificables de GitHub Actions. Todos generan reportes JSON publicados como artifacts aunque el pipeline se bloquee.
- El Quality Gate y el ruleset impidieron que código con hallazgos críticos llegara a `main`.
- La imagen desplegada en local es exactamente la escaneada por Trivy (tag `sha-<commit>` y label de revisión).
- Las correcciones de bajo costo (dependencia y runtime) cerraron 1 CVE crítico y la política de Conftest, y redujeron la imagen un 43%.
- La mayor parte del riesgo restante está en el código (SQLi, XSS, secretos, `permitAll`) y en las versiones de librerías que fija Spring Boot 3.5.14.

**Mejoras propuestas**
1. **Actualizar Spring Boot / dependencias gestionadas:** los 24 HIGH/CRITICAL restantes de Trivy están en `tomcat-embed-core 10.1.54`, `spring-webmvc`/`spring-expression 6.2.18`, `jackson-databind`/`jackson-core 2.21.2` y `micrometer-core 1.15.11`. Algunos solo tienen corrección en Spring Framework 7.x (CVE-2026-47884, CVE-2026-47890), por lo que conviene planificar la migración a Spring Boot 4.
2. Corregir en el código SQLi, XSS, secretos (mover a variables de entorno o un gestor de secretos), logging de credenciales, y restringir `permitAll` y CSRF.
3. Endurecer [application.properties](../src/main/resources/application.properties): no exponer todos los endpoints de Actuator ni la consola H2, y no incluir stacktraces en los errores.
4. Fijar acciones de GitHub y la imagen de Semgrep por SHA/digest.
5. Automatizar la importación a DefectDojo con la API (`/api/v2/reimport-scan/`) desde el pipeline.
6. Añadir DAST (p. ej. OWASP ZAP) sobre el despliegue local en una siguiente iteración.

## Anexos
- A. `conftest-report.json` (antes y después).
- B. Reportes JSON descargados de los artifacts de las ejecuciones de la sección 5.
- C. Capturas de DefectDojo y del despliegue local.
