require 'open3'
require 'timeout'
require 'net/http'
require 'uri'

module Parse
  module Test
    class DockerHelper
      COMPOSE_FILE = 'scripts/docker/docker-compose.test.yml'
      CONTAINER_NAME = 'parse-stack-test-server'
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
          uri = URI('http://localhost:2337/parse/health')
          response = Net::HTTP.get_response(uri)
          response.code == '200'
        rescue StandardError
          false
        end

        def exec(command)
          stdout, stderr, status = Open3.capture3("docker exec #{CONTAINER_NAME} #{command}")
          {
            stdout: stdout,
            stderr: stderr,
            success: status.success?
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
          system('docker --version', out: IO::NULL, err: IO::NULL)
        end

        def compose_file_exists?
          ::File.exist?(COMPOSE_FILE)
        end

        # Auto-start server for tests if ENV variable is set
        def auto_start_if_configured
          if ENV['PARSE_TEST_AUTO_START'] == 'true'
            start!
          end
        end

        # Clean shutdown on exit
        def setup_exit_handler
          at_exit do
            if ENV['PARSE_TEST_AUTO_STOP'] == 'true' && running?
              stop!
            end
          end
        end
      end
    end
  end
end