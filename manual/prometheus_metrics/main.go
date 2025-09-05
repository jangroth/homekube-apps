package main

import (
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Define a gauge metric. Gauges are for values that can go up and down.
// We'll use this to track a random value.
var (
	// myGauge is a gauge metric with the name "my_random_value".
	// The help string is a descriptive text for the metric.
	myGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "my_random_value",
		Help: "A random value that changes every second.",
	})
)

func init() {
	// Register the myGauge metric with Prometheus's default registry.
	// This is crucial for the metric to be exposed.
	prometheus.MustRegister(myGauge)
}

func main() {
	// Start a goroutine that updates the gauge metric every second.
	// This simulates a changing value in your application.
	go func() {
		for {
			// Set the gauge to a new random value.
			myGauge.Set(float64(rand.Intn(100)))

			// Wait for one second before the next update.
			time.Sleep(1 * time.Second)
		}
	}()

	// The `promhttp.Handler()` function returns an HTTP handler that exposes
	// the metrics from the default registry at the `/metrics` endpoint.
	http.Handle("/metrics", promhttp.Handler())

	// Start the HTTP server on port 8080.
	// We're listening on all network interfaces ("0.0.0.0").
	fmt.Println("Starting Prometheus metrics server on http://localhost:8080/metrics")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
