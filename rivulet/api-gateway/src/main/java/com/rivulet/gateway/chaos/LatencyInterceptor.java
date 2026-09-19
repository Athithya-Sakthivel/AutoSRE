package com.rivulet.gateway.chaos;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.util.concurrent.TimeUnit;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

/**
 * Injects artificial latency into configured business endpoints while the chaos latency fault is
 * enabled.
 */
@Component
public class LatencyInterceptor implements HandlerInterceptor {

    private static final long LATENCY_MS = 2_000L;

    private final ChaosService chaosService;

    public LatencyInterceptor(ChaosService chaosService) {
        this.chaosService = chaosService;
    }

    @Override
    public boolean preHandle(
            HttpServletRequest request, HttpServletResponse response, Object handler)
            throws Exception {
        if (!chaosService.isLatencyEnabled()) {
            return true;
        }

        try {
            TimeUnit.MILLISECONDS.sleep(LATENCY_MS);
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            throw ex;
        }

        return true;
    }
}
