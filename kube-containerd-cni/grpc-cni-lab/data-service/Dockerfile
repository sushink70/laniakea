# Build context is the repo root:  docker build -f data-service/Dockerfile .
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1

COPY data-service/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY proto/products.proto .
RUN python -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. products.proto

COPY data-service/server.py data-service/seed.json ./

EXPOSE 50051
CMD ["python", "server.py"]
