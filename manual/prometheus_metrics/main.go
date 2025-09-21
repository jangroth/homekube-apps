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
		Name: "pm_gauge_demo",
		Help: "A random value that changes every second.",
	})

	myCounter = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "pm_counter_demo_total",
		Help: "A counter that changes every 2 seconds",
	})

	mySummary = prometheus.NewSummary(prometheus.SummaryOpts{
		Name: "pm_summary_demo",
		Help: "A summary demo",
	})
)

func init() {
	// Register the myGauge metric with Prometheus's default registry.
	// This is crucial for the metric to be exposed.
	prometheus.MustRegister(myGauge, myCounter, mySummary)
}

func main() {
	// Start a goroutine that updates the gauge metric every second.
	// This simulates a changing value in your application.
	go func() {
		for {
			// Set the gauge to a new random value.
			myGauge.Set(float64(rand.Intn(100)))
			myCounter.Inc()

			time.Sleep(1 * time.Second)
		}
	}()

	http.Handle("/metrics", promhttp.Handler())
	http.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		time.Sleep(time.Duration(rand.Intn(2)) * time.Second)
		fmt.Fprintf(w, "Hello World - %.2f", time.Since(start).Seconds())
		mySummary.Observe(time.Since(start).Seconds())
	}))

	fmt.Println("Starting Prometheus metrics server on http://localhost:8080/metrics")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
