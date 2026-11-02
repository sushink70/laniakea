fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Needs `protoc` on PATH (the Dockerfile installs protobuf-compiler)
    tonic_build::compile_protos("proto/products.proto")?;
    Ok(())
}
