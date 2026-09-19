package com.rivulet.gateway.chaos;

import jakarta.annotation.PreDestroy;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import javax.sql.DataSource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Manages the state of injected faults for the SRE evaluation harness.
 *
 * <p>The service intentionally holds database connections open when the leak fault is enabled and
 * runs a CPU-consuming virtual thread when the CPU fault is enabled.
 *
 * <p>The {@code pause-consumer} fault from the Go worker is intentionally omitted because this Java
 * Gateway is not a queue consumer.
 */
@Service
public class ChaosService {

    private static final Logger log = LoggerFactory.getLogger(ChaosService.class);

    private static final int LEAK_COUNT = 10;

    private final DataSource dataSource;

    private final List<Connection> leakedConnections = new ArrayList<>();
    private final AtomicReference<Thread> cpuSpinner = new AtomicReference<>();
    private final AtomicBoolean latencyEnabled = new AtomicBoolean(false);

    public ChaosService(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /**
     * Intentionally borrows and retains database connections.
     *
     * @return JSON response describing the resulting leak state
     */
    public synchronized String leakDb() {
        if (!leakedConnections.isEmpty()) {
            return "{\"status\":\"already leaked\",\"count\":" + leakedConnections.size() + "}";
        }

        int acquired = 0;

        for (int i = 0; i < LEAK_COUNT; i++) {
            try {
                /*
                 * Intentionally do not close the connection here.
                 * The connection remains borrowed until reset() or shutdown.
                 */
                leakedConnections.add(dataSource.getConnection());
                acquired++;
            } catch (SQLException ex) {
                log.warn(
                        "Failed to acquire connection {} of {} for chaos leak",
                        i + 1,
                        LEAK_COUNT,
                        ex);
                break;
            }
        }

        return "{\"status\":\"leaked\",\"acquired\":" + acquired + "}";
    }

    /**
     * Starts a CPU-burning virtual thread unless one is already running.
     *
     * @return JSON response describing the resulting CPU-spinner state
     */
    public synchronized String cpuSpin() {
        Thread existing = cpuSpinner.get();

        if (existing != null && existing.isAlive()) {
            return "{\"status\":\"already running\"}";
        }

        Thread spinner =
                Thread.ofVirtual()
                        .name("chaos-cpu-spinner")
                        .start(
                                () -> {
                                    long value = 0L;

                                    try {
                                        while (!Thread.currentThread().isInterrupted()) {
                                            /*
                                             * Keep the computation observable enough that the
                                             * loop remains a real CPU workload rather than being
                                             * trivially reducible to an empty loop.
                                             */
                                            value =
                                                    Long.rotateLeft(
                                                            value + 0x9E3779B97F4A7C15L, 13);

                                            if ((value & 0xFFFFL) == 0L) {
                                                Thread.onSpinWait();
                                            }
                                        }
                                    } finally {
                                        log.debug("Chaos CPU spinner stopped");
                                    }
                                });

        cpuSpinner.set(spinner);

        return "{\"status\":\"started\"}";
    }

    /**
     * Enables the latency fault.
     *
     * @return JSON response describing the resulting latency state
     */
    public String latency() {
        latencyEnabled.set(true);
        return "{\"status\":\"injected\"}";
    }

    public boolean isLatencyEnabled() {
        return latencyEnabled.get();
    }

    /**
     * Resets every injected fault.
     *
     * @return JSON response describing reset completion
     */
    public synchronized String reset() {
        releaseLeakedConnections();
        stopCpuSpinner();
        latencyEnabled.set(false);

        return "{\"status\":\"reset complete\"}";
    }

    /** Ensures intentionally leaked resources are released during application shutdown. */
    @PreDestroy
    void shutdown() {
        reset();
    }

    private void releaseLeakedConnections() {
        if (leakedConnections.isEmpty()) {
            return;
        }

        int closeFailures = 0;

        for (Connection connection : leakedConnections) {
            if (connection == null) {
                continue;
            }

            try {
                if (!connection.isClosed()) {
                    connection.close();
                }
            } catch (SQLException ex) {
                closeFailures++;
                log.warn("Failed to close chaos-leaked database connection", ex);
            }
        }

        leakedConnections.clear();

        if (closeFailures > 0) {
            log.error(
                    "Failed to close {} chaos-leaked database connection(s) during reset",
                    closeFailures);
        }
    }

    private void stopCpuSpinner() {
        Thread spinner = cpuSpinner.getAndSet(null);

        if (spinner == null) {
            return;
        }

        if (spinner.isAlive()) {
            spinner.interrupt();
        }
    }
}
