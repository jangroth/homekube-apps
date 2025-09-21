# Makefile to simplify building and running the Go application and its Docker container.
# The name of our application binary.
BINARY_NAME=app

# The name of the Docker image.
IMAGE_NAME=prometheus-go-app

# The port to expose from the container.
PORT=8080

# The default target. Running 'make' without a target will build the binary.
all: build

# Build the Go binary.
build:
	go build -v -o $(BINARY_NAME) ./main.go

# Build the Docker image.
docker-build:
	docker build -t $(IMAGE_NAME) .

# Run the Docker container, mapping the port.
docker-run:
	docker run --rm -p $(PORT):$(PORT) $(IMAGE_NAME)

# Clean up the generated binary and stop any running containers.
clean:
	rm -f $(BINARY_NAME)
	docker stop $$(docker ps -q --filter ancestor=$(IMAGE_NAME)) || true

.PHONY: all build docker-build docker-run clean
