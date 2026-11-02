# Build context is the repo root:  docker build -f api-service/Dockerfile .
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1

COPY api-service/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY proto/products.proto .
RUN python -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. products.proto

COPY api-service/main.py ./

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
