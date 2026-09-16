package com.advarra.employee.persistence;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.Statement;

import javax.sql.DataSource;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.event.ContextClosedEvent;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;

/**
 * Periodically snapshots the H2 database (via H2's online "BACKUP TO" command,
 * which produces a consistent zip without needing to stop the app) and uploads
 * it to S3. Also runs one last backup on graceful shutdown.
 */
@Component
public class S3BackupService {

    private static final Logger log = LoggerFactory.getLogger(S3BackupService.class);

    private final DataSource dataSource;

    @Value("${app.persistence.s3.bucket:}")
    private String bucket;

    @Value("${app.persistence.s3.key:h2-backup/h2-db-backup.zip}")
    private String key;

    @Value("${app.persistence.s3.region:us-east-1}")
    private String region;

    @Value("${app.persistence.s3.local-backup-file:./data/h2-db-backup.zip}")
    private String localBackupFile;

    public S3BackupService(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @Scheduled(fixedDelayString = "#{${app.persistence.s3.backup-interval-minutes:5} * 60000}")
    public void scheduledBackup() {
        backupToS3();
    }

    @EventListener(ContextClosedEvent.class)
    public void onShutdown() {
        log.info("Application shutting down - running final S3 backup");
        backupToS3();
    }

    public void backupToS3() {
        if (bucket == null || bucket.isBlank()) {
            return;
        }
        try {
            Path zipPath = Path.of(localBackupFile).toAbsolutePath();
            Files.createDirectories(zipPath.getParent());
            Files.deleteIfExists(zipPath);

            try (Connection conn = dataSource.getConnection(); Statement st = conn.createStatement()) {
                st.execute("BACKUP TO '" + zipPath.toString().replace("'", "''") + "'");
            }

            S3Client s3 = S3Client.builder().region(Region.of(region)).build();
            try {
                s3.putObject(PutObjectRequest.builder().bucket(bucket).key(key).build(), RequestBody.fromFile(zipPath));
                log.info("Backed up H2 database to s3://{}/{}", bucket, key);
            } finally {
                s3.close();
            }
        } catch (Exception e) {
            log.error("Failed to back up H2 database to S3", e);
        }
    }
}
