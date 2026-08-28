-- Production schema: users table
-- Stores application users for JWT authentication and authorization.

CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'USER',
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_users_role CHECK (role IN ('USER', 'ADMIN'))
);

-- Indexes for lookups
CREATE INDEX idx_users_username ON users (username);
CREATE INDEX idx_users_email ON users (email);
