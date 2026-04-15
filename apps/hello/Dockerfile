# Offline-safe: pulled from Harbor mirror. Airgap gitea-runner cannot reach
# docker.io, so FROM must be the FQDN — the comment is not enough.
FROM harbor.airgap.local/mirror/python:3.12-slim

WORKDIR /app
COPY src/app.py /app/app.py

EXPOSE 8080
CMD ["python", "-u", "/app/app.py"]
