package com.prod.taskapi.service;

import com.prod.taskapi.dto.JwtResponse;
import com.prod.taskapi.dto.LoginRequest;
import com.prod.taskapi.dto.RegisterRequest;
import com.prod.taskapi.entity.Role;
import com.prod.taskapi.entity.User;
import com.prod.taskapi.repository.UserRepository;
import com.prod.taskapi.security.JwtService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class AuthService {

  private static final Logger log = LoggerFactory.getLogger(AuthService.class);

  private final UserRepository userRepository;
  private final PasswordEncoder passwordEncoder;
  private final JwtService jwtService;

  public AuthService(
      UserRepository userRepository, PasswordEncoder passwordEncoder, JwtService jwtService) {
    this.userRepository = userRepository;
    this.passwordEncoder = passwordEncoder;
    this.jwtService = jwtService;
  }

  @Transactional
  public JwtResponse register(RegisterRequest request) {
    log.info("Register attempt username={}", request.username());

    if (userRepository.existsByUsername(request.username())) {
      log.warn("Registration failed: username already exists username={}", request.username());
      throw new IllegalArgumentException("Username already taken");
    }
    if (userRepository.existsByEmail(request.email())) {
      log.warn("Registration failed: email already exists email={}", request.email());
      throw new IllegalArgumentException("Email already registered");
    }

    User user =
        new User(
            request.username(),
            request.email(),
            passwordEncoder.encode(request.password()),
            Role.USER);
    userRepository.save(user);

    log.info("User registered successfully username={}", user.getUsername());
    String token =
        jwtService.generateToken(user.getId(), user.getUsername(), user.getRole().name());
    return new JwtResponse(token, user.getUsername(), user.getRole().name());
  }

  public JwtResponse login(LoginRequest request) {
    log.info("Login attempt username={}", request.username());

    User user =
        userRepository
            .findByUsername(request.username())
            .orElseThrow(
                () -> {
                  log.warn("Login failed: user not found username={}", request.username());
                  return new BadCredentialsException("Invalid username or password");
                });

    if (!passwordEncoder.matches(request.password(), user.getPasswordHash())) {
      log.warn("Login failed: invalid password username={}", request.username());
      throw new BadCredentialsException("Invalid username or password");
    }

    String token =
        jwtService.generateToken(user.getId(), user.getUsername(), user.getRole().name());
    log.info("Login successful username={}", user.getUsername());
    return new JwtResponse(token, user.getUsername(), user.getRole().name());
  }
}
