# syntax=docker/dockerfile:1

# =============================================================================
# STAGE 1: build
# =============================================================================
# Official Maven image bundling Eclipse Temurin 17 (matches pom.xml's
# <java.version>17</java.version> and the parent's target). This stage
# contains a full JDK + Maven + build-time tooling — none of it belongs in
# the image that actually runs in production, which is the entire reason
# for a multi-stage build instead of one image that both compiles and runs.
# =============================================================================
FROM maven:3.9-eclipse-temurin-17 AS build

WORKDIR /build

# Dependency-layer caching: copy ONLY the pom first and resolve dependencies
# before copying any source code. Docker caches layers by content hash — as
# long as pom.xml is unchanged, this layer is reused on every subsequent
# build even if application code changes constantly, so a routine code
# change doesn't force a full ~100+ dependency re-download every CI run.
COPY pom.xml .
RUN mvn dependency:go-offline -B

# NOW copy source — this invalidates the cache only when code actually changes.
COPY src ./src

# Tests are NOT run here. They already ran as an explicit, separate CI stage
# before this Docker build even starts (see the GitHub Actions pipeline).
# Running them again inside the image build would (a) duplicate work,
# (b) require the build stage to reach out to a database or mocks, adding
# fragility to something that should be a fast, deterministic packaging
# step, and (c) hide test failures inside a Docker build log instead of a
# dedicated, clearly-labeled CI stage. -DskipTests is deliberate, not laziness.
RUN mvn clean package -DskipTests -B

# =============================================================================
# STAGE 2: runtime
# =============================================================================
# JRE-only, Alpine-based. Two decisions bundled here, both worth defending:
#
# JRE vs JDK: the running container never compiles anything — it only
# executes a jar. Shipping a compiler, javadoc tooling, and build-time
# libraries into a production image is pure attack surface and pure size
# with zero runtime benefit.
#
# Alpine vs Debian-slim (eclipse-temurin:17-jre-jammy): Alpine (musl libc)
# gives a meaningfully smaller image (~80MB smaller) than the Debian-based
# equivalent, and this app has no native/JNI dependencies that would be
# sensitive to musl vs glibc differences — a real risk for some Java
# workloads (certain native libraries, some DNS resolution edge cases), but
# not one that applies to a straightforward JPA/REST application. If this
# app later added a native dependency with known musl issues, jre-jammy
# would be the safer default and the size trade-off would be worth it.
# =============================================================================
FROM eclipse-temurin:17-jre-alpine

RUN apk update && apk upgrade --no-cache

# Non-root user: if the app is ever compromised (a dependency vuln, a
# deserialization bug), the process should not have root inside its own
# container. Fixed, non-default UID/GID rather than an arbitrary system
# user, so it's deterministic across builds and easy to reference in an
# ECS task definition if a specific user needs to be enforced there too.
RUN addgroup -g 1001 spring && adduser -D -u 1001 -G spring spring

WORKDIR /app

# --chown at copy time avoids a separate RUN chown layer (which would
# duplicate the jar's bytes across two image layers).
COPY --from=build --chown=spring:spring /build/target/*.jar app.jar

USER spring

EXPOSE 8080

# Container-level healthcheck — useful for local `docker run`/docker-compose
# use and for `docker ps` visibility. This is NOT what ECS actually uses for
# routing decisions (the ALB target group health check, configured in
# Terraform, is authoritative there) — the two are complementary, not
# redundant: this one helps a developer running the container locally.
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD wget -qO- http://localhost:8080/actuator/health | grep -q '"status":"UP"' || exit 1

# Exec form (JSON array) — runs as PID 1 directly, receives SIGTERM properly
# for graceful shutdown. The shell form (`CMD java -jar app.jar`) would run
# java as a child of a shell process, which can swallow or delay signal
# forwarding during container stop — the kind of thing that turns a clean
# ECS deployment drain into a hard-killed connection instead
ENTRYPOINT ["java", "-jar", "app.jar"]