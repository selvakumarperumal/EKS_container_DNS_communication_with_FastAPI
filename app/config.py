from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "fastapidb"
    db_user: str = "fastapi"
    db_password: str = ""

    aws_s3_bucket: str = ""
    aws_region: str = "ap-south-1"

    redis_host: str = "localhost"
    redis_port: int = 6379

    otel_service_name: str = "fastapi-app"
    otel_exporter_otlp_endpoint: str = "http://localhost:4317"

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

    @property
    def redis_url(self) -> str:
        return f"redis://{self.redis_host}:{self.redis_port}/0"


settings = Settings()
