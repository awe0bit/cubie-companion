FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY backend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt \
    && groupadd --gid 10001 corenest \
    && useradd --uid 10001 --gid 10001 --no-create-home corenest \
    && install -d -o 10001 -g 10001 -m 700 /data
COPY backend/*.py ./
COPY backend/web ./web
USER 10001:10001
EXPOSE 18766
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD python -c "import socket; s=socket.create_connection(('127.0.0.1',18766),3); s.sendall(b'GET /pair HTTP/1.0\r\nHost: localhost\r\n\r\n'); assert b' 200 ' in s.makefile('rb').readline(128); s.close()"
CMD ["python", "/app/bootstrap.py"]
