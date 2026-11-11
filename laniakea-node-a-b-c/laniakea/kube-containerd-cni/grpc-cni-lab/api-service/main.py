"""Service B - REST API (GET/POST/DELETE) that talks to Service A over gRPC."""
import os

import grpc
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field

import products_pb2 as pb
import products_pb2_grpc as pb_grpc

DATA_SERVICE_ADDR = os.getenv("DATA_SERVICE_ADDR", "data-service:50051")
RPC_TIMEOUT = float(os.getenv("RPC_TIMEOUT", "3"))

POD_NAME = os.getenv("POD_NAME", "unknown")
NODE_NAME = os.getenv("NODE_NAME", "unknown")
POD_IP = os.getenv("POD_IP", "unknown")

channel = grpc.insecure_channel(DATA_SERVICE_ADDR)
stub = pb_grpc.ProductServiceStub(channel)

app = FastAPI(title="api-service (B)", description="REST gateway -> gRPC -> data-service (A)")


class ProductIn(BaseModel):
    name: str = Field(min_length=1)
    category: str = "general"
    price: float = Field(ge=0)
    stock: int = Field(default=0, ge=0)


def to_dict(p):
    return {"id": p.id, "name": p.name, "category": p.category, "price": p.price, "stock": p.stock}


def rpc(method, request):
    """Call a gRPC method and translate gRPC errors to HTTP errors."""
    try:
        return method(request, timeout=RPC_TIMEOUT)
    except grpc.RpcError as e:
        code = e.code()
        detail = e.details()
        if code == grpc.StatusCode.NOT_FOUND:
            raise HTTPException(404, detail)
        if code == grpc.StatusCode.INVALID_ARGUMENT:
            raise HTTPException(400, detail)
        if code == grpc.StatusCode.DEADLINE_EXCEEDED:
            raise HTTPException(504, f"data-service timed out ({DATA_SERVICE_ADDR})")
        if code == grpc.StatusCode.UNAVAILABLE:
            raise HTTPException(503, f"data-service unreachable ({DATA_SERVICE_ADDR})")
        raise HTTPException(502, f"{code.name}: {detail}")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/products")
def list_products(category: str = Query(default="")):
    resp = rpc(stub.ListProducts, pb.ListProductsRequest(category=category))
    return [to_dict(p) for p in resp.products]


@app.get("/products/{product_id}")
def get_product(product_id: int):
    return to_dict(rpc(stub.GetProduct, pb.GetProductRequest(id=product_id)))


@app.post("/products", status_code=201)
def create_product(body: ProductIn):
    p = rpc(stub.CreateProduct, pb.CreateProductRequest(
        name=body.name, category=body.category, price=body.price, stock=body.stock))
    return to_dict(p)


@app.delete("/products/{product_id}")
def delete_product(product_id: int):
    rpc(stub.DeleteProduct, pb.DeleteProductRequest(id=product_id))
    return {"deleted": product_id}


@app.get("/whoami")
def whoami():
    """Shows where B and A run - they should be on different nodes with different pod IPs."""
    a = rpc(stub.Info, pb.InfoRequest())
    return {
        "api_service_B": {"pod": POD_NAME, "node": NODE_NAME, "pod_ip": POD_IP},
        "data_service_A": {"pod": a.pod_name, "node": a.node_name, "pod_ip": a.pod_ip,
                           "product_count": a.product_count},
        "grpc_target": DATA_SERVICE_ADDR,
    }
