# Spring Boot DevSecOps Lab

Aplicacion deliberadamente vulnerable para prácticas controladas de SAST, SCA,
secret scanning, análisis de contenedores y DAST.

> **Advertencia:** ejecutar únicamente en `localhost` o en una red de laboratorio
> aislada. No desplegar en Internet ni reutilizar credenciales reales.

## Requisitos

- JDK 21
- Maven 3.9+
- Docker, opcional
- Semgrep, para el análisis local

## Iniciar la aplicación

```bash
mvn clean verify
mvn spring-boot:run
```

La aplicación estará disponible en `http://localhost:8080`.

## Endpoints del laboratorio

```text
GET  /api/products/search?name=Laptop
POST /api/comments/preview
GET  /api/admin/users/1
POST /api/auth/login
```

Ejemplo para la vista previa:

```bash
curl -X POST http://localhost:8080/api/comments/preview \
  -H "Content-Type: application/json" \
  -d '{"comment":"Comentario de prueba"}'
```

Ejemplo de autenticación:

```bash
curl -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"usuario","password":"prueba"}'
```

## Pipeline CI/CD y despliegue local

Flujo: `push` a la rama → GitHub Actions compila y prueba → SAST (Semgrep, CodeQL,
SpotBugs/PMD) → Policy as Code (Conftest) → construye la imagen del proyecto, la
escanea con Trivy y publica **esa misma imagen** en GHCR como `sha-<commit>` y
`<rama>` → Quality Gate. Todos los reportes JSON quedan como artifacts de la ejecución.

El despliegue local (CD) se inicia manualmente descargando la imagen publicada
(PowerShell; el paquete es privado: usar un PAT con `read:packages`):

```powershell
$env:CR_PAT | docker login ghcr.io -u <usuario-github> --password-stdin
$SHA = "<7 primeros caracteres del commit>"
docker pull ghcr.io/marioquimetmed/spring-boot-webapi-secure:sha-$SHA
docker run -d --name webapi -p 8081:8080 ghcr.io/marioquimetmed/spring-boot-webapi-secure:sha-$SHA
docker ps                                       # STATUS -> (healthy)
curl.exe http://localhost:8081/actuator/health
```

Se usa el puerto 8081 porque DefectDojo ocupa el 8080. Para detenerla: `docker rm -f webapi`.

## Semgrep local

```bash
semgrep scan --config auto --config .semgrep.yml src/main/java
```

El docente dispone de `docs/GUIA-DOCENTE.md`, que contiene el catálogo de
hallazgos y las pruebas sugeridas. Se recomienda entregar inicialmente a los
estudiantes el resto del repositorio sin dicho documento.
