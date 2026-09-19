package com.rivulet.gateway.config;

import com.rivulet.gateway.chaos.LatencyInterceptor;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

@Configuration(proxyBeanMethods = false)
public class WebConfig implements WebMvcConfigurer {

    private final LatencyInterceptor latencyInterceptor;

    public WebConfig(LatencyInterceptor latencyInterceptor) {
        this.latencyInterceptor = latencyInterceptor;
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(latencyInterceptor).addPathPatterns("/orders/**", "/inventory/**");
    }
}
