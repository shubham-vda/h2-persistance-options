FROM eclipse-temurin:17-jre-jammy

WORKDIR /app
COPY target/employee-service.jar app.jar

# Overridden per-task by the ECS task definition to point at the EFS mount.
ENV DB_DATA_DIR=/data

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
