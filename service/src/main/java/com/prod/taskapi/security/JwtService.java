package com.prod.taskapi.security;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;

@Service
public class JwtService {

    private static final Logger log = LoggerFactory.getLogger(JwtService.class);

    private final SecretKey signingKey;
    private final long expirationMs;

    public JwtService(
            @Value("${jwt.secret}") String secret,
            @Value("${jwt.expiration-ms:86400000}") long expirationMs) {

        if (secret == null || secret.length() < 32) {
            throw new IllegalStateException("JWT secret must be at least 32 characters long");
        }
        this.signingKey = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
        this.expirationMs = expirationMs;
        log.info("JwtService initialized with expiration {} ms", expirationMs);
    }

    public String generateToken(Long userId, String username, String role) {
        Instant now = Instant.now();
        Instant expiry = now.plusMillis(expirationMs);

        return Jwts.builder()
                .subject(username)
                .claim("userId", userId)
                .claim("role", role)
                .issuedAt(Date.from(now))
                .expiration(Date.from(expiry))
                .signWith(signingKey)
                .compact();
    }

    public String extractUsername(String token) {
        return parseClaims(token).getSubject();
    }

    public Long extractUserId(String token) {
        Number userId = parseClaims(token).get("userId", Number.class);
        return userId != null ? userId.longValue() : null;
    }

    public String extractRole(String token) {
        return parseClaims(token).get("role", String.class);
    }

    public boolean isTokenValid(String token, String username) {
        try {
            Claims claims = parseClaims(token);
            return claims.getSubject().equals(username) && claims.getExpiration().after(new Date());
        } catch (Exception e) {
            log.debug("JWT validation failed: {}", e.getMessage());
            return false;
        }
    }

    private Claims parseClaims(String token) {
        return Jwts.parser()
                .verifyWith(signingKey)
                .build()
                .parseSignedClaims(token)
                .getPayload();
    }
}