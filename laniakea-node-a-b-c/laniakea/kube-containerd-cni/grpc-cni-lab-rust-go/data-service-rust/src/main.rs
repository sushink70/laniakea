//! Service A - gRPC data service backed by a JSON file (mock database). Rust + tonic.

use std::{env, fs, path::Path};

use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use tonic::{transport::Server, Request, Response, Status};

pub mod pb {
    tonic::include_proto!("products.v1");
}
use pb::product_service_server::{ProductService, ProductServiceServer};
use pb::{
    CreateProductRequest, DeleteProductRequest, DeleteProductResponse, GetProductRequest,
    InfoRequest, InfoResponse, ListProductsRequest, ListProductsResponse, Product,
};

/// One row of the JSON "database".
#[derive(Serialize, Deserialize, Clone)]
struct Record {
    id: i32,
    name: String,
    category: String,
    price: f64,
    stock: i32,
}

#[derive(Serialize, Deserialize)]
struct Db {
    products: Vec<Record>,
}

fn to_pb(r: &Record) -> Product {
    Product {
        id: r.id,
        name: r.name.clone(),
        category: r.category.clone(),
        price: r.price,
        stock: r.stock,
    }
}

struct Svc {
    db_path: String,
    lock: Mutex<()>, // serialises read-modify-write on the JSON file
    pod_name: String,
    node_name: String,
    pod_ip: String,
}

impl Svc {
    fn load(&self) -> Result<Db, Status> {
        let text = fs::read_to_string(&self.db_path)
            .map_err(|e| Status::internal(format!("read db: {e}")))?;
        serde_json::from_str(&text).map_err(|e| Status::internal(format!("parse db: {e}")))
    }

    fn save(&self, db: &Db) -> Result<(), Status> {
        let tmp = format!("{}.tmp", self.db_path);
        let text = serde_json::to_string_pretty(db)
            .map_err(|e| Status::internal(format!("encode db: {e}")))?;
        fs::write(&tmp, text).map_err(|e| Status::internal(format!("write db: {e}")))?;
        fs::rename(&tmp, &self.db_path).map_err(|e| Status::internal(format!("rename db: {e}")))
    }

    // remote_addr() is the caller's pod IP - proof the traffic crossed the CNI
    fn log<T>(&self, method: &str, req: &Request<T>) {
        match req.remote_addr() {
            Some(a) => println!("[A] {method} from {a}"),
            None => println!("[A] {method} from unknown"),
        }
    }
}

#[tonic::async_trait]
impl ProductService for Svc {
    async fn list_products(
        &self,
        request: Request<ListProductsRequest>,
    ) -> Result<Response<ListProductsResponse>, Status> {
        self.log("ListProducts", &request);
        let category = request.into_inner().category;
        let _g = self.lock.lock().await;
        let db = self.load()?;
        let products = db
            .products
            .iter()
            .filter(|p| category.is_empty() || p.category == category)
            .map(to_pb)
            .collect();
        Ok(Response::new(ListProductsResponse { products }))
    }

    async fn get_product(
        &self,
        request: Request<GetProductRequest>,
    ) -> Result<Response<Product>, Status> {
        let id = request.get_ref().id;
        self.log(&format!("GetProduct({id})"), &request);
        let _g = self.lock.lock().await;
        let db = self.load()?;
        db.products
            .iter()
            .find(|p| p.id == id)
            .map(|p| Response::new(to_pb(p)))
            .ok_or_else(|| Status::not_found(format!("product {id} not found")))
    }

    async fn create_product(
        &self,
        request: Request<CreateProductRequest>,
    ) -> Result<Response<Product>, Status> {
        self.log("CreateProduct", &request);
        let req = request.into_inner();
        if req.name.trim().is_empty() {
            return Err(Status::invalid_argument("name is required"));
        }
        let _g = self.lock.lock().await;
        let mut db = self.load()?;
        let new_id = db.products.iter().map(|p| p.id).max().unwrap_or(0) + 1;
        let rec = Record {
            id: new_id,
            name: req.name.trim().to_string(),
            category: if req.category.is_empty() {
                "general".to_string()
            } else {
                req.category
            },
            price: req.price,
            stock: req.stock,
        };
        db.products.push(rec.clone());
        self.save(&db)?;
        Ok(Response::new(to_pb(&rec)))
    }

    async fn delete_product(
        &self,
        request: Request<DeleteProductRequest>,
    ) -> Result<Response<DeleteProductResponse>, Status> {
        let id = request.get_ref().id;
        self.log(&format!("DeleteProduct({id})"), &request);
        let _g = self.lock.lock().await;
        let mut db = self.load()?;
        let before = db.products.len();
        db.products.retain(|p| p.id != id);
        if db.products.len() == before {
            return Err(Status::not_found(format!("product {id} not found")));
        }
        self.save(&db)?;
        Ok(Response::new(DeleteProductResponse { deleted: true }))
    }

    async fn info(&self, request: Request<InfoRequest>) -> Result<Response<InfoResponse>, Status> {
        self.log("Info", &request);
        let _g = self.lock.lock().await;
        let count = self.load()?.products.len() as i32;
        Ok(Response::new(InfoResponse {
            service: "data-service (A, rust)".to_string(),
            pod_name: self.pod_name.clone(),
            node_name: self.node_name.clone(),
            pod_ip: self.pod_ip.clone(),
            product_count: count,
        }))
    }
}

fn env_or(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn ensure_db(db_path: &str, seed_path: &str) -> std::io::Result<()> {
    if let Some(dir) = Path::new(db_path).parent() {
        fs::create_dir_all(dir)?;
    }
    if !Path::new(db_path).exists() {
        fs::copy(seed_path, db_path)?;
        println!("[A] seeded database at {db_path}");
    }
    Ok(())
}

// PID 1 in a container ignores SIGTERM unless we handle it
async fn shutdown_signal() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut term = signal(SignalKind::terminate()).expect("sigterm handler");
    let mut int = signal(SignalKind::interrupt()).expect("sigint handler");
    tokio::select! {
        _ = term.recv() => {},
        _ = int.recv() => {},
    }
    println!("[A] shutting down");
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let db_path = env_or("DB_PATH", "/data/db.json");
    let seed_path = env_or("SEED_PATH", "/app/seed.json");
    let port = env_or("GRPC_PORT", "50051");

    ensure_db(&db_path, &seed_path)?;

    let svc = Svc {
        db_path,
        lock: Mutex::new(()),
        pod_name: env_or("POD_NAME", "unknown"),
        node_name: env_or("NODE_NAME", "unknown"),
        pod_ip: env_or("POD_IP", "unknown"),
    };

    let addr: std::net::SocketAddr = format!("0.0.0.0:{port}").parse()?;
    println!(
        "[A] gRPC server listening on {addr} (pod={} node={} ip={})",
        svc.pod_name, svc.node_name, svc.pod_ip
    );

    Server::builder()
        .add_service(ProductServiceServer::new(svc))
        .serve_with_shutdown(addr, shutdown_signal())
        .await?;
    Ok(())
}
