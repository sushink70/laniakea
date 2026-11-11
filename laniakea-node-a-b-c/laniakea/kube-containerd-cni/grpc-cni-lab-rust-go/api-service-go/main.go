// Service B - REST API (GET/POST/DELETE) that talks to Service A over gRPC. Go, net/http + grpc-go.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	pb "api-service/gen/productspb"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

type productJSON struct {
	ID       int32   `json:"id"`
	Name     string  `json:"name"`
	Category string  `json:"category"`
	Price    float64 `json:"price"`
	Stock    int32   `json:"stock"`
}

func toJSON(p *pb.Product) productJSON {
	return productJSON{ID: p.Id, Name: p.Name, Category: p.Category, Price: p.Price, Stock: p.Stock}
}

type server struct {
	client   pb.ProductServiceClient
	timeout  time.Duration
	target   string
	podName  string
	nodeName string
	podIP    string
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// rpcError translates a gRPC status into an HTTP status.
func (s *server) rpcError(w http.ResponseWriter, err error) {
	st, ok := status.FromError(err)
	if !ok {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	switch st.Code() {
	case codes.NotFound:
		writeErr(w, http.StatusNotFound, st.Message())
	case codes.InvalidArgument:
		writeErr(w, http.StatusBadRequest, st.Message())
	case codes.DeadlineExceeded:
		writeErr(w, http.StatusGatewayTimeout, "data-service timed out ("+s.target+")")
	case codes.Unavailable:
		writeErr(w, http.StatusServiceUnavailable, "data-service unreachable ("+s.target+")")
	default:
		writeErr(w, http.StatusBadGateway, st.Code().String()+": "+st.Message())
	}
}

func (s *server) ctx(r *http.Request) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), s.timeout)
}

func (s *server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) listProducts(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := s.ctx(r)
	defer cancel()
	resp, err := s.client.ListProducts(ctx, &pb.ListProductsRequest{Category: r.URL.Query().Get("category")})
	if err != nil {
		s.rpcError(w, err)
		return
	}
	out := make([]productJSON, 0, len(resp.Products))
	for _, p := range resp.Products {
		out = append(out, toJSON(p))
	}
	writeJSON(w, http.StatusOK, out)
}

func parseID(w http.ResponseWriter, r *http.Request) (int32, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 32)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "id must be an integer")
		return 0, false
	}
	return int32(id), true
}

func (s *server) getProduct(w http.ResponseWriter, r *http.Request) {
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	ctx, cancel := s.ctx(r)
	defer cancel()
	p, err := s.client.GetProduct(ctx, &pb.GetProductRequest{Id: id})
	if err != nil {
		s.rpcError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toJSON(p))
}

type createBody struct {
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    *float64 `json:"price"`
	Stock    int32    `json:"stock"`
}

func (s *server) createProduct(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var body createBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return
	}
	switch {
	case strings.TrimSpace(body.Name) == "":
		writeErr(w, http.StatusUnprocessableEntity, "name is required")
		return
	case body.Price == nil || *body.Price < 0:
		writeErr(w, http.StatusUnprocessableEntity, "price is required and must be >= 0")
		return
	case body.Stock < 0:
		writeErr(w, http.StatusUnprocessableEntity, "stock must be >= 0")
		return
	}
	ctx, cancel := s.ctx(r)
	defer cancel()
	p, err := s.client.CreateProduct(ctx, &pb.CreateProductRequest{
		Name: body.Name, Category: body.Category, Price: *body.Price, Stock: body.Stock,
	})
	if err != nil {
		s.rpcError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, toJSON(p))
}

func (s *server) deleteProduct(w http.ResponseWriter, r *http.Request) {
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	ctx, cancel := s.ctx(r)
	defer cancel()
	if _, err := s.client.DeleteProduct(ctx, &pb.DeleteProductRequest{Id: id}); err != nil {
		s.rpcError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int32{"deleted": id})
}

// whoami shows where the Go REST API (Node B) and Rust gRPC service (Node C) run.
func (s *server) whoami(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := s.ctx(r)
	defer cancel()
	a, err := s.client.Info(ctx, &pb.InfoRequest{})
	if err != nil {
		s.rpcError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"api_service_B":  map[string]string{"pod": s.podName, "node": s.nodeName, "pod_ip": s.podIP},
		"data_service_A": map[string]any{"service": a.Service, "pod": a.PodName, "node": a.NodeName, "pod_ip": a.PodIp, "product_count": a.ProductCount},
		"grpc_target":    s.target,
	})
}

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("[B] %s %s from %s (%s)", r.Method, r.URL.RequestURI(), r.RemoteAddr, time.Since(start).Round(time.Microsecond))
	})
}

func main() {
	target := env("DATA_SERVICE_ADDR", "data-service.demo.svc.cluster.local:50051")
	timeout, err := time.ParseDuration(env("RPC_TIMEOUT", "3s"))
	if err != nil {
		log.Fatalf("bad RPC_TIMEOUT: %v", err)
	}

	// NewClient is lazy: it connects on first RPC and re-resolves DNS as needed.
	conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("grpc client: %v", err)
	}
	defer conn.Close()

	s := &server{
		client:   pb.NewProductServiceClient(conn),
		timeout:  timeout,
		target:   target,
		podName:  env("POD_NAME", "unknown"),
		nodeName: env("NODE_NAME", "unknown"),
		podIP:    env("POD_IP", "unknown"),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /whoami", s.whoami)
	mux.HandleFunc("GET /products", s.listProducts)
	mux.HandleFunc("GET /products/{id}", s.getProduct)
	mux.HandleFunc("POST /products", s.createProduct)
	mux.HandleFunc("DELETE /products/{id}", s.deleteProduct)

	srv := &http.Server{
		Addr:              ":" + env("PORT", "8080"),
		Handler:           logging(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		stop := make(chan os.Signal, 1)
		signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
		<-stop
		log.Println("[B] shutting down")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()

	log.Printf("[B] REST listening on %s -> gRPC %s (pod=%s node=%s ip=%s)", srv.Addr, target, s.podName, s.nodeName, s.podIP)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
