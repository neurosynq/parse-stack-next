require "webrick"
require "rack"
require "socket"

module Parse
  module Test
    # In-process WEBrick server that mounts the Parse::Webhooks Rack app
    # for end-to-end webhook integration tests. Parse Server (running in
    # Docker) reaches it via `host.docker.internal:<port>`.
    #
    # Rack 3 removed `Rack::Handler::WEBrick`, so this class includes a
    # minimal WEBrick-to-Rack request adapter directly rather than
    # depending on `rackup`.
    class WebhookTestServer
      # Hostname Parse Server uses to reach the test host. Docker Desktop
      # (macOS/Windows) resolves this natively; on Linux, docker-compose
      # must add `extra_hosts: ["host.docker.internal:host-gateway"]`.
      DOCKER_HOST = "host.docker.internal".freeze

      attr_reader :port, :url, :app

      def initialize(app: Parse::Webhooks, port: nil, bind: "0.0.0.0")
        @app = app
        @bind = bind
        @port = port || find_free_port
        @url = "http://#{DOCKER_HOST}:#{@port}".freeze
        @last_responses = []
      end

      def start!
        @server = WEBrick::HTTPServer.new(
          Port: @port,
          BindAddress: @bind,
          Logger: WEBrick::Log.new(::File::NULL, WEBrick::Log::FATAL),
          AccessLog: [],
        )
        @server.mount_proc("/") do |req, res|
          dispatch_to_rack(req, res)
        end
        @thread = Thread.new { @server.start }
        wait_until_ready
        self
      end

      def stop!
        @server&.shutdown
        @thread&.join(5)
        @server = nil
        @thread = nil
      end

      # All response bodies seen by this server during the test, for
      # introspection / debugging.
      attr_reader :last_responses

      private

      def find_free_port
        s = TCPServer.new("127.0.0.1", 0)
        port = s.addr[1]
        s.close
        port
      end

      def wait_until_ready(deadline_seconds: 5)
        deadline = Time.now + deadline_seconds
        while Time.now < deadline
          begin
            TCPSocket.new("127.0.0.1", @port).close
            return
          rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
            sleep 0.05
          end
        end
        raise "WebhookTestServer did not become ready on port #{@port}"
      end

      def dispatch_to_rack(req, res)
        env = rack_env_from(req)
        status, headers, body = @app.call(env)
        body_str = +""
        body.each { |chunk| body_str << chunk }
        body.close if body.respond_to?(:close)
        res.status = status
        headers.each { |k, v| res[k] = v }
        res.body = body_str
        @last_responses << { path: req.path, status: status, body: body_str }
      end

      def rack_env_from(req)
        body_str = req.body || ""
        env = {
          "REQUEST_METHOD" => req.request_method,
          "PATH_INFO" => req.path,
          "QUERY_STRING" => req.query_string.to_s,
          "SERVER_NAME" => req.host,
          "SERVER_PORT" => req.port.to_s,
          "CONTENT_TYPE" => req.content_type || "application/json",
          "CONTENT_LENGTH" => body_str.bytesize.to_s,
          "rack.version" => [1, 3],
          "rack.input" => StringIO.new(body_str),
          "rack.errors" => $stderr,
          "rack.multithread" => true,
          "rack.multiprocess" => false,
          "rack.run_once" => false,
          "rack.url_scheme" => "http",
        }
        # Forward all HTTP headers as HTTP_*
        req.each do |name, value|
          key = "HTTP_" + name.to_s.upcase.tr("-", "_")
          env[key] = value.to_s
        end
        env
      end
    end
  end
end
