package com.rivulet.gateway.config;

import com.rivulet.gateway.chaos.ChaosController;
import com.sun.net.httpserver.HttpServer;
import jakarta.annotation.PreDestroy;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Configures the isolated chaos injection HTTP server.
 *
 * <p>The server listens on a separate port and is not part of the Spring MVC routing tree. Exposure
 * outside the process is a deployment/networking concern and must be controlled by Kubernetes
 * Service/Ingress/NetworkPolicy configuration.
 */
@Configuration(proxyBeanMethods = false)
public class ChaosConfig {

    private static final Logger log = LoggerFactory.getLogger(ChaosConfig.class);

    private static final int BACKLOG = 0;
    private static final int SHUTDOWN_DELAY_SECONDS = 5;

    private volatile HttpServer chaosServer;
    private volatile ExecutorService chaosExecutor;

    @Bean
    public HttpServer chaosServer(
            @Value("${rivulet.chaos.port:8081}") int port, ChaosController controller)
            throws IOException {
        ThreadFactory virtualThreadFactory = Thread.ofVirtual().name("chaos-http-", 0).factory();

        ExecutorService executor = Executors.newThreadPerTaskExecutor(virtualThreadFactory);

        try {
            HttpServer server = HttpServer.create(new InetSocketAddress(port), BACKLOG);

            /*
             * Every HTTP exchange is dispatched to a dedicated virtual thread.
             * The server itself still has its own internal background thread,
             * as specified by the JDK HttpServer implementation.
             */
            server.setExecutor(executor);

            server.createContext("/healthz", controller::handleHealthz);
            server.createContext("/__chaos/leak-db", controller::handleLeakDb);
            server.createContext("/__chaos/cpu-spin", controller::handleCpuSpin);
            server.createContext("/__chaos/latency", controller::handleLatency);
            server.createContext("/__chaos/reset", controller::handleReset);

            server.start();

            chaosServer = server;
            chaosExecutor = executor;

            log.info("Chaos server started on {}", server.getAddress());

            return server;
        } catch (RuntimeException | IOException ex) {
            executor.shutdownNow();
            throw ex;
        }
    }

    /**
     * HttpServer exposes stop(int), not a no-argument stop(). Shutdown is therefore handled
     * explicitly here rather than through an invalid Spring destroyMethod declaration.
     */
    @PreDestroy
    void shutdownChaosServer() {
        HttpServer server = chaosServer;
        ExecutorService executor = chaosExecutor;

        chaosServer = null;
        chaosExecutor = null;

        if (server != null) {
            try {
                server.stop(SHUTDOWN_DELAY_SECONDS);
            } catch (RuntimeException ex) {
                log.warn("Failed to stop chaos HTTP server cleanly", ex);
            }
        }

        if (executor != null) {
            executor.shutdownNow();
        }

        log.info("Chaos server shutdown complete");
    }
}
