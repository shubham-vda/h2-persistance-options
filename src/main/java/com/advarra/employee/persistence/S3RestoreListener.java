package com.advarra.employee.persistence;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationEnvironmentPreparedEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.core.env.ConfigurableEnvironment;

import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.HeadObjectRequest;

/**
 * Restores the H2 database from S3 (if a backup exists there) before Spring
 * creates the DataSource bean, so the file is already in place by the time
 * H2 opens it. Registered directly with SpringApplication in main() since it
 * must run earlier than normal @Component beans.
 */
public class S3RestoreListener implements ApplicationListener<ApplicationEnvironmentPreparedEvent> {

    private static final Logger log = LoggerFactory.getLogger(S3RestoreListener.class);

    @Override
    public void onApplicationEvent(ApplicationEnvironmentPreparedEvent event) {
        ConfigurableEnvironment env = event.getEnvironment();
        String bucket = env.getProperty("app.persistence.s3.bucket", "");
        if (bucket.isBlank()) {
            log.info("app.persistence.s3.bucket is not set - skipping S3 restore, using local H2 file only");
            return;
        }

        String key = env.getProperty("app.persistence.s3.key", "h2-backup/h2-db-backup.zip");
        String region = env.getProperty("app.persistence.s3.region", "us-east-1");
        String dataDir = env.getProperty("app.persistence.data-dir", "./data");
        String localZip = env.getProperty("app.persistence.s3.local-backup-file", "./data/h2-db-backup.zip");

        S3Client s3 = S3Client.builder().region(Region.of(region)).build();
        try {
            try {
                s3.headObject(HeadObjectRequest.builder().bucket(bucket).key(key).build());
            } catch (NoSuchKeyException e) {
                log.info("No existing S3 backup found at s3://{}/{} - starting with a fresh database", bucket, key);
                return;
            }

            Path zipPath = Path.of(localZip);
            Files.createDirectories(zipPath.toAbsolutePath().getParent());
            s3.getObject(GetObjectRequest.builder().bucket(bucket).key(key).build(), zipPath);

            extractZip(zipPath, Path.of(dataDir));
            log.info("Restored H2 database from s3://{}/{}", bucket, key);
        } catch (Exception e) {
            log.error("Failed to restore H2 database from S3 - continuing with local/fresh database", e);
        } finally {
            s3.close();
        }
    }

    private void extractZip(Path zipFile, Path targetDir) throws IOException {
        Path absoluteTarget = targetDir.toAbsolutePath().normalize();
        Files.createDirectories(absoluteTarget);
        try (ZipInputStream zis = new ZipInputStream(Files.newInputStream(zipFile))) {
            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                Path target = absoluteTarget.resolve(entry.getName()).normalize();
                if (!target.startsWith(absoluteTarget)) {
                    throw new IOException("Zip entry outside target directory: " + entry.getName());
                }
                if (entry.isDirectory()) {
                    Files.createDirectories(target);
                } else {
                    Files.createDirectories(target.getParent());
                    Files.copy(zis, target, StandardCopyOption.REPLACE_EXISTING);
                }
                zis.closeEntry();
            }
        }
    }
}
