package com.rivulet.gateway.telemetry;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Propagates the client-provided {@code X-Request-ID} header into the SLF4J MDC for application log
 * correlation.
 *
 * <p>OpenTelemetry/Micrometer trace correlation is handled by the HTTP observation infrastructure.
 * This filter intentionally does not manipulate the active span, avoiding coupling to servlet
 * filter ordering.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 100)
public final class TraceFilter extends OncePerRequestFilter {

    private static final String REQUEST_ID_HEADER = "X-Request-ID";
    private static final String MDC_REQUEST_ID = "requestId";
    private static final int MAX_REQUEST_ID_LENGTH = 256;

    @Override
    protected void doFilterInternal(
            HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {

        String requestId = normalizeRequestId(request.getHeader(REQUEST_ID_HEADER));

        if (requestId == null) {
            filterChain.doFilter(request, response);
            return;
        }

        String previousRequestId = MDC.get(MDC_REQUEST_ID);
        MDC.put(MDC_REQUEST_ID, requestId);

        try {
            filterChain.doFilter(request, response);
        } finally {
            restoreMdcValue(previousRequestId);
        }
    }

    private static void restoreMdcValue(String previousRequestId) {
        if (previousRequestId == null) {
            MDC.remove(MDC_REQUEST_ID);
        } else {
            MDC.put(MDC_REQUEST_ID, previousRequestId);
        }
    }

    private static String normalizeRequestId(String rawRequestId) {
        if (rawRequestId == null) {
            return null;
        }

        String requestId = rawRequestId.trim();

        if (requestId.isEmpty() || requestId.length() > MAX_REQUEST_ID_LENGTH) {
            return null;
        }

        for (int i = 0; i < requestId.length(); i++) {
            if (Character.isISOControl(requestId.charAt(i))) {
                return null;
            }
        }

        return requestId;
    }
}
