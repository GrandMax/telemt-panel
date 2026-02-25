import asyncio
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.staticfiles import StaticFiles


class SpaStaticFiles(StaticFiles):
    """Serve static files with SPA fallback: unknown paths return index.html."""

    def lookup_path(self, path: str):
        full_path, stat_result = super().lookup_path(path)
        if stat_result is None:
            return super().lookup_path("index.html")
        return full_path, stat_result


from app.database import engine, Base, SessionLocal
from app.routers import admin, user, system
from app.services.metrics_scraper import fetch_metrics, scrape_and_persist
from app.services.user_service import get_active_users_for_config
from app.services.config_writer import write_config
from app.config import settings

# When running in Docker, static/ is next to backend/ (parent of app/)
STATIC_DIR = Path(__file__).resolve().parent.parent.parent / "static"


async def _metrics_loop(app: FastAPI):
    last_values: dict[str, tuple[int, int]] = {}
    interval = max(1, settings.metrics_scrape_interval_seconds)
    while True:
        await asyncio.sleep(interval)
        if not settings.telemt_metrics_url:
            continue
        try:
            text = await fetch_metrics()
            db = SessionLocal()
            try:
                last_values = scrape_and_persist(db, text, last_values)
            finally:
                db.close()
        except Exception:
            logging.exception("Metrics scrape failed")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Run Alembic migrations so new columns (e.g. last_seen_at) exist
    try:
        from alembic import command
        from alembic.config import Config
        import sqlalchemy.exc
        backend_dir = Path(__file__).resolve().parent.parent
        alembic_cfg = Config(str(backend_dir / "alembic.ini"))
        try:
            command.upgrade(alembic_cfg, "head")
        except sqlalchemy.exc.OperationalError as e:
            # DB may have been created by create_all() earlier; tables exist but alembic_version is empty
            if "already exists" in str(e.orig).lower():
                command.stamp(alembic_cfg, "001")
                command.upgrade(alembic_cfg, "head")
            else:
                raise
    except Exception:
        logging.exception("Alembic upgrade failed")
    Base.metadata.create_all(bind=engine)
    if settings.telemt_config_path:
        db = SessionLocal()
        try:
            write_config(get_active_users_for_config(db))
        finally:
            db.close()
    task = asyncio.create_task(_metrics_loop(app))
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="MTProxy Panel", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(system.router)
app.include_router(admin.router)
app.include_router(user.router)

if STATIC_DIR.is_dir():
    app.mount("/", SpaStaticFiles(directory=str(STATIC_DIR), html=True), name="static")
else:

    @app.get("/")
    def root():
        return {"service": "mtpanel-panel", "docs": "/docs"}
