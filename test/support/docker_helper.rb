require "open3"
require "timeout"
require "net/http"
require "uri"

module Parse
  module Test
    class DockerHelper
      COMPOSE_FILE = "scripts/docker/docker-compose.test.yml"
      CONTAINER_NAME = "#{ENV["PSNEXT_PREFIX"] || "psnext-it"}-server"
      STARTUP_TIMEOUT = 30

      class << self
        def start!
          return true if running?

          puts "Starting Parse Server test container..."

          stdout, stderr, status = Open3.capture3("docker-compose -f #{COMPOSE_FILE} up -d")

          if status.success?
            wait_for_server
          else
            puts "Failed to start containers: #{stderr}"
            false
          end
        end

        def stop!
          puts "Stopping Parse Server test container..."
          system("docker-compose -f #{COMPOSE_FILE} down", out: IO::NULL, err: IO::NULL)
        end

        def restart!
          stop!
          start!
        end

        # ---------------------------------------------------------------
        # Server-only lifecycle controls. Unlike stop!/start!/restart!
        # (which run `docker-compose down`/`up` and therefore tear down
        # the WHOLE stack — including mongo, wiping all data), these act
        # on the Parse Server container ALONE via `docker stop|start|
        # restart`. Mongo and Redis stay up and keep their volumes, so a
        # disruptive test can simulate a server outage / restart without
        # destroying the database the rest of the suite depends on.
        #
        # Used by the disruptive integration tests:
        #   test/lib/parse/network_failure_disruptive_test.rb
        #   test/lib/parse/webhook_restart_disruptive_test.rb
        # ---------------------------------------------------------------

        # Stop ONLY the Parse Server container. Mongo/Redis keep running,
        # so this is a clean "server went away" simulation. Returns true
        # on success.
        def stop_server!
          system("docker stop #{CONTAINER_NAME}", out: IO::NULL, err: IO::NULL)
        end

        # Start ONLY the Parse Server container (after stop_server!) and
        # block until /health responds. Returns the wait_for_server
        # result (true when ready, false on timeout).
        def start_server!
          system("docker start #{CONTAINER_NAME}", out: IO::NULL, err: IO::NULL)
          wait_for_server
        end

        # Restart ONLY the Parse Server container in place (preserving
        # mongo data and any server-side state persisted there, such as
        # registered webhooks) and block until /health responds.
        def restart_server!
          system("docker restart #{CONTAINER_NAME}", out: IO::NULL, err: IO::NULL)
          wait_for_server
        end

        # Idempotent best-effort restore: ensure the Parse Server
        # container is running and healthy. Safe to call from a test
        # teardown / ensure block regardless of current state — a no-op
        # when the server already answers /health. Returns true once the
        # server is ready.
        def ensure_server_running!
          return true if server_ready?
          start_server!
        end

        def running?
          stdout, = Open3.capture3("docker ps --filter name=#{CONTAINER_NAME} --format '{{.Names}}'")
          stdout.strip == CONTAINER_NAME
        end

        def logs(lines: 50)
          stdout, = Open3.capture3("docker logs #{CONTAINER_NAME} --tail #{lines}")
          stdout
        end

        def status
          stdout, = Open3.capture3("docker-compose -f #{COMPOSE_FILE} ps")
          stdout
        end

        def wait_for_server
          Timeout.timeout(STARTUP_TIMEOUT) do
            loop do
              if server_ready?
                puts "✓ Parse Server is ready!"
                return true
              end
              sleep 1
              print "."
            end
          end
        rescue Timeout::Error
          puts "\n✗ Parse Server failed to start within #{STARTUP_TIMEOUT} seconds"
          puts "Container logs:"
          puts logs(lines: 100)
          false
        end

        def server_ready?
          uri = URI("#{ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse"}/health")
          response = Net::HTTP.get_response(uri)
          response.code == "200"
        rescue StandardError
          false
        end

        def exec(command)
          stdout, stderr, status = Open3.capture3("docker exec #{CONTAINER_NAME} #{command}")
          {
            stdout: stdout,
            stderr: stderr,
            success: status.success?,
          }
        end

        # Ensure containers are available
        def ensure_available!
          unless docker_installed?
            raise "Docker is not installed. Please install Docker to run tests with a real Parse Server."
          end

          unless compose_file_exists?
            raise "Docker Compose file not found at #{COMPOSE_FILE}"
          end

          true
        end

        def docker_installed?
          system("docker --version", out: IO::NULL, err: IO::NULL)
        end

        def compose_file_exists?
          ::File.exist?(COMPOSE_FILE)
        end

        # Auto-start server for tests if ENV variable is set
        def auto_start_if_configured
          if ENV["PARSE_TEST_AUTO_START"] == "true"
            start!
          end
        end

        # Clean shutdown on exit
        def setup_exit_handler
          at_exit do
            if ENV["PARSE_TEST_AUTO_STOP"] == "true" && running?
              stop!
            end
          end
        end
      end
    end
  end
end
