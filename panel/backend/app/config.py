"""Panel configuration from environment."""
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Database
    database_url: str = "sqlite:///./panel.db"

    # JWT
    secret_key: str = "change-me-in-production"
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 1440  # 24h

    # Telemt
    telemt_config_path: str = ""
    telemt_metrics_url: str = "http://localhost:9090/metrics"
    telemt_ignore_time_skew: bool = False  # from TELEMT_IGNORE_TIME_SKEW (true/1 = True)
    proxy_host: str = "localhost"
    proxy_port: int = 443
    tls_domain: str = "example.com"

    # Server
    host: str = "0.0.0.0"
    port: int = 8080


settings = Settings()
