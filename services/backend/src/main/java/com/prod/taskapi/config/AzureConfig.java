package com.prod.taskapi.config;

import com.azure.core.credential.TokenCredential;
import com.azure.identity.DefaultAzureCredentialBuilder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class AzureConfig {

  private static final Logger log = LoggerFactory.getLogger(AzureConfig.class);

  @Bean
  public TokenCredential azureTokenCredential() {
    log.info("Creating DefaultAzureCredential for Azure SDK clients");
    return new DefaultAzureCredentialBuilder().build();
  }
}
