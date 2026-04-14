# Offline-safe: python:3.12-slim is in platform/harbor/images/IMAGES.txt
# and mirrored at harbor.airgap.local/mirror/python:3.12-slim.
FROM python:3.12-slim

WORKDIR /app
COPY src/app.py /app/app.py

EXPOSE 8080
CMD ["python", "-u", "/app/app.py"]
