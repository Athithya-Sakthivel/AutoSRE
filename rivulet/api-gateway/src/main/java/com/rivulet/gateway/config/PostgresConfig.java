package com.rivulet.gateway.config;

import javax.sql.DataSource;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * PostgreSQL infrastructure configuration.
 *
 * <p>Spring Boot auto-configures the DataSource from {@code spring.datasource.*}. Flyway is also
 * auto-configured and runs pending migrations at startup when the Flyway starter is present and
 * enabled.
 *
 * <p>This configuration only exposes the JdbcTemplate used for direct SQL access. It does not
 * create or manually trigger Flyway migrations because Spring Boot already owns that lifecycle.
 */
@Configuration(proxyBeanMethods = false)
public class PostgresConfig {

    /**
     * Creates a JdbcTemplate backed by the application's DataSource.
     *
     * @param dataSource the auto-configured PostgreSQL DataSource
     * @return a JdbcTemplate for SQL access
     */
    @Bean
    public JdbcTemplate jdbcTemplate(DataSource dataSource) {
        return new JdbcTemplate(dataSource);
    }
}
