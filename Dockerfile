# ---- Build stage ----
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /app

# pom primero: las dependencias quedan en cache mientras no cambie el pom
COPY pom.xml .
RUN mvn dependency:go-offline -B

# Copy source and build
COPY src src
RUN mvn package -DskipTests -B

# ---- Runtime stage ----
# Runtime solo con JRE (sin compilador ni herramientas del JDK): menos superficie de ataque
FROM eclipse-temurin:21-jre-alpine

# Security: run as non-root user (Alpine usa addgroup/adduser)
RUN addgroup -S spring && adduser -S -G spring spring

WORKDIR /app

# Copy only the fat jar
COPY --from=builder /app/target/*.jar app.jar

USER spring:spring

# Optional: expose actuator / app port
EXPOSE 8080

# Health check (wget viene en Alpine; curl no)
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD wget -qO- http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["java", "-XX:+UseContainerSupport", "-XX:MaxRAMPercentage=75.0", "-jar", "app.jar"]
