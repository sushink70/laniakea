"""Service A - gRPC data service backed by a JSON file (mock database)."""
import json
import os
import shutil
import threading
from concurrent import futures

import grpc
import products_pb2 as pb
import products_pb2_grpc as pb_grpc

DB_PATH = os.getenv("DB_PATH", "/data/db.json")
SEED_PATH = os.getenv("SEED_PATH", "/app/seed.json")
GRPC_PORT = os.getenv("GRPC_PORT", "50051")

POD_NAME = os.getenv("POD_NAME", "unknown")
NODE_NAME = os.getenv("NODE_NAME", "unknown")
POD_IP = os.getenv("POD_IP", "unknown")

lock = threading.Lock()


def ensure_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    if not os.path.exists(DB_PATH):
        shutil.copy(SEED_PATH, DB_PATH)
        print(f"[A] seeded database at {DB_PATH}", flush=True)


def load():
    with open(DB_PATH) as f:
        return json.load(f)


def save(data):
    tmp = DB_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, DB_PATH)


def to_pb(p):
    return pb.Product(
        id=p["id"], name=p["name"], category=p["category"],
        price=p["price"], stock=p["stock"],
    )


def log(method, context):
    # context.peer() shows the caller's pod IP - proof the traffic crossed the CNI
    print(f"[A] {method} from {context.peer()}", flush=True)


class ProductService(pb_grpc.ProductServiceServicer):
    def ListProducts(self, request, context):
        log("ListProducts", context)
        with lock:
            db = load()
        items = [
            to_pb(p) for p in db["products"]
            if not request.category or p["category"] == request.category
        ]
        return pb.ListProductsResponse(products=items)

    def GetProduct(self, request, context):
        log(f"GetProduct({request.id})", context)
        with lock:
            db = load()
        for p in db["products"]:
            if p["id"] == request.id:
                return to_pb(p)
        context.abort(grpc.StatusCode.NOT_FOUND, f"product {request.id} not found")

    def CreateProduct(self, request, context):
        log("CreateProduct", context)
        if not request.name.strip():
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, "name is required")
        with lock:
            db = load()
            new_id = max((p["id"] for p in db["products"]), default=0) + 1
            item = {
                "id": new_id,
                "name": request.name.strip(),
                "category": request.category or "general",
                "price": request.price,
                "stock": request.stock,
            }
            db["products"].append(item)
            save(db)
        return to_pb(item)

    def DeleteProduct(self, request, context):
        log(f"DeleteProduct({request.id})", context)
        with lock:
            db = load()
            before = len(db["products"])
            db["products"] = [p for p in db["products"] if p["id"] != request.id]
            deleted = len(db["products"]) < before
            if deleted:
                save(db)
        if not deleted:
            context.abort(grpc.StatusCode.NOT_FOUND, f"product {request.id} not found")
        return pb.DeleteProductResponse(deleted=True)

    def Info(self, request, context):
        log("Info", context)
        with lock:
            count = len(load()["products"])
        return pb.InfoResponse(
            service="data-service (A)", pod_name=POD_NAME, node_name=NODE_NAME,
            pod_ip=POD_IP, product_count=count,
        )


def serve():
    ensure_db()
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    pb_grpc.add_ProductServiceServicer_to_server(ProductService(), server)
    server.add_insecure_port(f"[::]:{GRPC_PORT}")
    server.start()
    print(f"[A] gRPC server listening on :{GRPC_PORT} (pod={POD_NAME} node={NODE_NAME} ip={POD_IP})", flush=True)
    server.wait_for_termination()


if __name__ == "__main__":
    serve()
