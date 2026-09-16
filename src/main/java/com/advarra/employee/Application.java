package com.advarra.employee;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

import com.advarra.employee.persistence.S3RestoreListener;

@SpringBootApplication
@EnableScheduling
public class Application {

    public static void main(String[] args) {
        SpringApplication app = new SpringApplication(Application.class);
        // Must run before the DataSource bean is created, so it's registered
        // directly with SpringApplication rather than as a normal @Component.
        app.addListeners(new S3RestoreListener());
        app.run(args);
    }
}
