"""Gunicorn settings. Every value can be overridden from the environment."""

import os

bind = f"0.0.0.0:{os.environ.get('PORT', '8080')}"
workers = int(os.environ.get("WEB_CONCURRENCY", "2"))
worker_class = "gthread"
threads = int(os.environ.get("GUNICORN_THREADS", "4"))
timeout = 30
graceful_timeout = 20

# Must be LONGER than the ALB idle timeout (60s). If the app closes an idle
# keep-alive connection first, the ALB can race a new request onto a socket
# that is being torn down and return a 502 to the client.
keepalive = 75

# Recycle workers periodically to bound the damage from slow memory/fd leaks.
# The pre-deploy diagnostics flag worker restarts during the load test as a
# crash, so keep this well above the number of requests that test sends.
max_requests = 10000
max_requests_jitter = 1000

accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("LOG_LEVEL", "info").lower()
