package com.rivulet.gateway.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;

/**
 * Valkey/Redis stream infrastructure.
 *
 * <p>Valkey is accessed through the Redis-compatible protocol supported by Spring Data Redis.
 * Spring Boot auto-configures the Redis connection factory and a StringRedisTemplate when the Redis
 * starter is present.
 *
 * <p>This configuration explicitly exposes the StringRedisTemplate so gateway components have a
 * stable, application-owned injection point for string-based stream operations.
 */
@Configuration(proxyBeanMethods = false)
public class ValkeyConfig {

    /**
     * Creates a StringRedisTemplate backed by the auto-configured connection factory.
     *
     * <p>The template supports Redis Streams through {@code opsForStream()}.
     *
     * @param connectionFactory Spring Boot's Redis connection factory
     * @return a StringRedisTemplate for stream and string operations
     */
    @Bean
    public StringRedisTemplate stringRedisTemplate(RedisConnectionFactory connectionFactory) {
        return new StringRedisTemplate(connectionFactory);
    }
}
