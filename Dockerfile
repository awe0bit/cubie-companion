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
HEALTHCHECK --interval=15s --timeout=3s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; r=urllib.request.build_opener(urllib.request.ProxyHandler({})).open('http://127.0.0.1:18766/pair',timeout=2); assert r.status==200"
CMD ["python", "/app/bootstrap.py"]
