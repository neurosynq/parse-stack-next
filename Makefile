# Parse Stack Test Server Makefile

.PHONY: test-server test-server-start test-server-stop test-server-restart test-connection test-integration clean help

# Start the test server
test-server-start:
	@echo "Starting Parse Server test containers..."
	docker-compose -f scripts/docker/docker-compose.test.yml up -d
	@echo "Waiting for services to start..."
	@sleep 10
	@echo "Parse Server available at: http://localhost:1337/parse"
	@echo "Parse Dashboard available at: http://localhost:4040"

# Stop the test server
test-server-stop:
	@echo "Stopping Parse Server test containers..."
	docker-compose -f scripts/docker/docker-compose.test.yml down

# Restart the test server
test-server-restart: test-server-stop test-server-start

# Test connection to Parse Server
test-connection:
	@echo "Testing Parse Server connection..."
	ruby scripts/test_server_connection.rb

# Run integration tests with test server
test-integration:
	@echo "Running integration tests..."
	PARSE_TEST_USE_DOCKER=true bundle exec rake test

# Clean up containers and volumes
clean:
	@echo "Cleaning up containers and volumes..."
	docker-compose -f scripts/docker/docker-compose.test.yml down -v
	docker system prune -f

# View Parse Server logs
logs:
	docker logs parse-stack-test-server -f

# View all container logs
logs-all:
	docker-compose -f scripts/docker/docker-compose.test.yml logs -f

# Show container status
status:
	docker-compose -f scripts/docker/docker-compose.test.yml ps

# Help
help:
	@echo "Parse Stack Test Server Commands:"
	@echo ""
	@echo "  make test-server-start    - Start Parse Server containers"
	@echo "  make test-server-stop     - Stop Parse Server containers"
	@echo "  make test-server-restart  - Restart Parse Server containers"
	@echo "  make test-connection      - Test connection to Parse Server"
	@echo "  make test-integration     - Run integration tests"
	@echo "  make logs                 - View Parse Server logs"
	@echo "  make logs-all            - View all container logs"
	@echo "  make status              - Show container status"
	@echo "  make clean               - Clean up containers and volumes"
	@echo "  make help                - Show this help message"