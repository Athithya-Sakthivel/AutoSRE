package com.rivulet.gateway.chaos;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

import java.sql.Connection;
import java.sql.SQLException;
import javax.sql.DataSource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

/**
 * Unit tests for {@link ChaosService} with a mocked DataSource.
 *
 * <p>Tests the fault injection logic without requiring a real database.
 */
@ExtendWith(MockitoExtension.class)
class ChaosServiceTest {

    @Mock private DataSource dataSource;

    @Mock private Connection connection;

    private ChaosService chaosService;

    @BeforeEach
    void setUp() {
        chaosService = new ChaosService(dataSource);
    }

    @Test
    void leakDb_acquiresConnections() throws SQLException {
        when(dataSource.getConnection()).thenReturn(connection);

        String result = chaosService.leakDb();

        assertThat(result).contains("\"status\":\"leaked\"");
        verify(dataSource, times(10)).getConnection();
    }

    @Test
    void leakDb_alreadyLeaked_returnsAlreadyLeaked() throws SQLException {
        when(dataSource.getConnection()).thenReturn(connection);
        chaosService.leakDb();

        String result = chaosService.leakDb();

        assertThat(result).contains("\"status\":\"already leaked\"");
        verify(dataSource, times(10)).getConnection(); // Still only 10 total
    }

    @Test
    void cpuSpin_startsSpinner() {
        String result = chaosService.cpuSpin();

        assertThat(result).contains("\"status\":\"started\"");
    }

    @Test
    void cpuSpin_alreadyRunning_returnsAlreadyRunning() {
        chaosService.cpuSpin();
        String result = chaosService.cpuSpin();

        assertThat(result).contains("\"status\":\"already running\"");
    }

    @Test
    void latency_enablesFlag() {
        assertThat(chaosService.isLatencyEnabled()).isFalse();

        String result = chaosService.latency();

        assertThat(result).contains("\"status\":\"injected\"");
        assertThat(chaosService.isLatencyEnabled()).isTrue();
    }

    @Test
    void reset_clearsAllFaults() throws SQLException {
        when(dataSource.getConnection()).thenReturn(connection);
        chaosService.leakDb();
        chaosService.cpuSpin();
        chaosService.latency();

        String result = chaosService.reset();

        assertThat(result).contains("\"status\":\"reset complete\"");
        assertThat(chaosService.isLatencyEnabled()).isFalse();
        verify(connection, times(10)).close();
    }

    @Test
    void shutdown_invokesReset() throws SQLException {
        when(dataSource.getConnection()).thenReturn(connection);
        chaosService.leakDb();
        chaosService.latency();

        // Invoke @PreDestroy method directly
        chaosService.shutdown();

        assertThat(chaosService.isLatencyEnabled()).isFalse();
        verify(connection, times(10)).close();
    }
}
