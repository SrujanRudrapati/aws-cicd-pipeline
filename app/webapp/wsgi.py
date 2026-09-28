"""Gunicorn entry point: `gunicorn webapp.wsgi:app`."""

import logging
import os

from webapp import create_app

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

app = create_app()
