# syntax=docker/dockerfile:1.7
# Build context is the repository root:
#   docker build -f app/Dockerfile --build-arg APP_VERSION=$(git rev-parse HEAD) .

FROM python:3.15-slim AS builder
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY app/requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt

FROM python:3.15-slim AS runtime
ARG APP_VERSION=dev
LABEL org.opencontainers.image.source="https://github.com/SrujanRudrapati/aws-cicd-pipeline" \
      org.opencontainers.image.revision="${APP_VERSION}"
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION} \
    PORT=8080

RUN groupadd --system app \
 && useradd --system --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv
WORKDIR /srv
COPY app/webapp ./webapp
COPY app/gunicorn.conf.py ./gunicorn.conf.py

# Stdlib-only diagnostics shipped with the image so the exact checks that gate
# a deploy can be re-run on a live host:  docker exec app python /opt/diag/sysdiag.py
COPY scripts/diagnostics/sysdiag.py /opt/diag/sysdiag.py

USER app
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)" || exit 1

CMD ["gunicorn", "--config", "gunicorn.conf.py", "webapp.wsgi:app"]
