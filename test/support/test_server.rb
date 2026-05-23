require 'net/http'
require 'json'

module Parse
  module Test
    class ServerHelper
      DEFAULT_CONFIG = {
        server_url: ENV['PARSE_TEST_SERVER_URL'] || 'http://localhost:2337/parse',
        app_id: ENV['PARSE_TEST_APP_ID'] || 'myAppId',
        api_key: ENV['PARSE_TEST_API_KEY'] || 'test-rest-key',
        master_key: ENV['PARSE_TEST_MASTER_KEY'] || 'myMasterKey'
      }.freeze

      class << self
        def setup(config = {})
          config = DEFAULT_CONFIG.merge(config)
          
          Parse::Client.setup(
            server_url: config[:server_url],
            app_id: config[:app_id],
            api_key: config[:api_key],
            master_key: config[:master_key],
            logging: ENV['PARSE_DEBUG'] ? :debug : false  # Disable Parse logging by default
          )
          
          if server_available?
            puts "✓ Connected to Parse Server at #{config[:server_url]}"
            true
          else
            puts "✗ Could not connect to Parse Server at #{config[:server_url]}"
            puts "  Run 'docker-compose -f scripts/docker/docker-compose.test.yml up' to start test server"
            false
          end
        end

        def server_available?
          uri = URI(Parse::Client.client.server_url + '/health')
          response = Net::HTTP.get_response(uri)
          response.code == '200'
        rescue StandardError => e
          # Fallback: Try to check if Parse is responding at all
          begin
            uri = URI(Parse::Client.client.server_url)
            response = Net::HTTP.get_response(uri)
            # Parse Server typically returns 404 or 401 for root path but it means server is up
            ['200', '404', '401', '403'].include?(response.code)
          rescue StandardError => e2
            false
          end
        end

        def reset_database!
          return unless Parse::Client.client.master_key.present?
          
          # Get all classes except system classes
          response = Parse::Client.client.schemas(use_master_key: true)
          schemas = response.results
          
          user_classes = schemas.reject do |s|
            s['className'].start_with?('_')
          end
          
          # Delete all objects from user classes
          user_classes.each do |schema|
            class_name = schema['className']
            begin
              total_deleted = 0
              attempts = 0
              max_attempts = 50  # Safety limit to prevent infinite loops
              
              loop do
                attempts += 1
                break if attempts > max_attempts
                
                # Always fetch from skip=0 since we're deleting objects
                fresh_query = Parse::Query.new(class_name).limit(100)
                objects = fresh_query.results
                break if objects.empty?
                
                # Delete objects
                objects.each do |obj|
                  begin
                    obj.destroy
                    total_deleted += 1
                  rescue => e
                    # Silent failure - continue with other objects
                  end
                end
              end
              
            rescue StandardError => e
              # Silent failure - continue with other classes  
            end
          end
        end

        def seed_data(&block)
          return unless block_given?
          
          puts "Seeding test data..."
          instance_eval(&block)
          puts "Seeding complete"
        end

        def create_test_user(username: nil, password: nil, email: nil)
          username ||= "test_#{SecureRandom.hex(4)}"
          password ||= 'password123'
          email ||= "#{username}@test.com"
          
          user = Parse::User.new(
            username: username,
            password: password,
            email: email
          )
          user.save
          user
        end

        def with_server(&block)
          if server_available?
            yield
          else
            puts "[WARNING] Server health check failed, but attempting to continue anyway..."
            # Try to run the test anyway since Docker containers started
            yield
          end
        end
      end
    end

    # Test context manager for isolated tests
    class Context
      attr_reader :created_objects

      def initialize
        @created_objects = []
      end

      def track(object)
        @created_objects << object if object.respond_to?(:destroy)
        object
      end

      def cleanup!
        @created_objects.each do |obj|
          obj.destroy rescue nil
        end
        @created_objects.clear
      end
    end

    # Mock server for unit tests that don't need real server
    class MockServer
      def self.stub_request(method, path, response_body, status = 200)
        # This would integrate with WebMock or similar library
        # For now, just a placeholder
        {
          method: method,
          path: path,
          response: {
            status: status,
            body: response_body
          }
        }
      end

      def self.stub_query(class_name, results = [])
        stub_request(:get, "/classes/#{class_name}", {
          results: results,
          count: results.length
        }.to_json)
      end

      def self.stub_save(class_name, object_data)
        stub_request(:post, "/classes/#{class_name}", {
          objectId: SecureRandom.hex(10),
          createdAt: Time.now.iso8601,
          **object_data
        }.to_json, 201)
      end
    end
  end
end