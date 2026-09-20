"""Alembic environment configuration for PostgreSQL via psycopg 3."""

from __future__ import annotations

import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool
from sqlalchemy.engine import URL, Connection, make_url

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Import the application's SQLAlchemy metadata here when it exists, for example:
#
# from autosre.persistence.models import Base
# target_metadata = Base.metadata
#
# Keep this as None until the application's canonical metadata object is
# available. Alembic can still run explicit/manual migrations normally.
target_metadata = None

# These tables are owned and migrated internally by
# langgraph-checkpoint-postgres via AsyncPostgresSaver.setup().
# They must not be managed by application Alembic migrations.
CHECKPOINT_TABLES = frozenset(
    {
        "checkpoint_migrations",
        "checkpoints",
        "checkpoint_blobs",
        "checkpoint_writes",
    }
)


def get_url() -> str:
    """Build a synchronous SQLAlchemy PostgreSQL URL for Alembic."""
    dsn = os.getenv("POSTGRES_DSN")

    if dsn:
        try:
            url = make_url(dsn)
        except Exception as exc:
            raise RuntimeError("POSTGRES_DSN is not a valid PostgreSQL URL") from exc

        if url.get_backend_name() != "postgresql":
            raise RuntimeError("POSTGRES_DSN must use a PostgreSQL URL")

        return url.set(drivername="postgresql+psycopg").render_as_string(hide_password=False)

    user = os.getenv("POSTGRES_USER", "autosre_agent")
    password = os.getenv("POSTGRES_PASSWORD", "")
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", "5432")
    database = os.getenv("POSTGRES_DB", "autosre_state")

    try:
        port_number = int(port)
    except ValueError as exc:
        raise RuntimeError("POSTGRES_PORT must be an integer") from exc

    url = URL.create(
        drivername="postgresql+psycopg",
        username=user,
        password=password,
        host=host,
        port=port_number,
        database=database,
    )

    return url.render_as_string(hide_password=False)


def include_object(
    object_: object,
    name: str | None,
    type_: str,
    reflected: bool,
    compare_to: object | None,
) -> bool:
    """Exclude LangGraph-managed checkpoint tables from autogenerate."""
    del object_, reflected, compare_to

    return not (type_ == "table" and name in CHECKPOINT_TABLES)


def run_migrations_offline() -> None:
    """Run migrations without creating a database connection."""
    context.configure(
        url=get_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        include_object=include_object,
        compare_type=True,
        compare_server_default=True,
    )

    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    """Configure and execute migrations on an active connection."""
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        include_object=include_object,
        compare_type=True,
        compare_server_default=True,
    )

    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Run migrations using SQLAlchemy's synchronous psycopg dialect."""
    configuration = config.get_section(
        config.config_ini_section,
        {},
    )

    configuration["sqlalchemy.url"] = get_url()

    connectable = engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        do_run_migrations(connection)


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
