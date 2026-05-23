# Parse Stack Test Server Setup

This document explains how to set up a local Parse Server for testing the parse-stack Ruby SDK.

## Quick Start

### Option 1: Using Make (Recommended)

```bash
# Start the test server
make test-server-start

# Test the connection
make test-connection

# Run integration tests
make test-integration

# Stop the test server
make test-server-stop
```

### Option 2: Docker Compose

1. **Start the test server:**
   ```bash
   docker-compose -f docker-compose.test.yml up -d
   ```

2. **Test the connection:**
   ```bash
   ruby test_server_connection.rb
   ```

3. **Run integration tests:**
   ```bash
   PARSE_TEST_USE_DOCKER=true bundle exec rake test
   ```

4. **Stop the test server:**
   ```bash
   docker-compose -f docker-compose.test.yml down
   ```

### Option 3: Use Your Own Parse Server

Set environment variables to point to your Parse Server:

```bash
export PARSE_TEST_SERVER_URL="http://your-server:1337/parse"
export PARSE_TEST_APP_ID="your-app-id"
export PARSE_TEST_API_KEY="your-rest-key"  
export PARSE_TEST_MASTER_KEY="your-master-key"
```

## Services Included

The Docker Compose setup provides:

- **MongoDB** (port 27017): Database backend
- **Parse Server** (port 1337): Main API server with custom startup script
- **Parse Dashboard** (port 4040): Web interface for data management

## Technical Implementation

### Custom Parse Server Image

The setup uses a custom Docker image built on top of `parseplatform/parse-server:8.2.3` that includes:

- **Custom startup script** (`scripts/start-parse.sh`) that sets the `PARSE_SERVER_MASTER_KEY_IPS` environment variable
- **IP restriction bypass** allowing requests from any IP address (`0.0.0.0/0,::/0`)
- **Automatic environment variable setup** for proper master key authentication

### Master Key Authentication

The setup resolves Parse Server's IP restriction for master key usage by:

1. Using a custom Docker image with an embedded startup script
2. Setting `PARSE_SERVER_MASTER_KEY_IPS=0.0.0.0/0,::/0` to allow all IP addresses
3. This enables schema operations and full master key functionality for testing

### File Structure

```
parse-stack-next/
├── scripts/
│   ├── docker/
│   │   ├── docker-compose.test.yml # Main Docker Compose configuration
│   │   └── Dockerfile.parse       # Custom Parse Server image
│   ├── start-parse.sh             # Startup script with environment setup
│   └── test_server_connection.rb  # Connection test script
├── config/
│   └── parse-config.json    # Parse Server configuration (unused)
├── test/
│   ├── cloud/
│   │   └── main.js         # Cloud Code for testing
│   └── support/
│       ├── test_server.rb   # Ruby test helper utilities
│       └── docker_helper.rb # Docker container management
└── .env.test              # Environment variable defaults
```

## Test Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PARSE_TEST_SERVER_URL` | `http://localhost:1337/parse` | Parse Server URL |
| `PARSE_TEST_APP_ID` | `myAppId` | Application ID |
| `PARSE_TEST_API_KEY` | `test-rest-key` | REST API Key |
| `PARSE_TEST_MASTER_KEY` | `myMasterKey` | Master Key |
| `PARSE_TEST_USE_DOCKER` | `false` | Auto-manage Docker containers |
| `PARSE_TEST_AUTO_START` | `false` | Start containers automatically |
| `PARSE_TEST_AUTO_STOP` | `false` | Stop containers on exit |

### Using `.env.test`

Copy and customize the test environment file:

```bash
cp .env.test .env.test.local
# Edit .env.test.local with your settings
```

## Writing Integration Tests

### Basic Setup

```ruby
require_relative 'test_helper_integration'

class MyIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  
  def test_user_creation
    with_parse_server do
      user = create_test_user(username: 'testuser')
      assert user.id.present?
      assert_equal 'testuser', user.username
    end
  end
end
```

### Test Helpers Available

- `with_parse_server { }` - Skip test if server unavailable
- `create_test_user(attributes)` - Create and track test user
- `create_test_object(class_name, attributes)` - Create and track test object
- `reset_database!` - Clear all non-system data
- `@test_context.track(object)` - Track object for cleanup

### Manual Server Management

```ruby
# In your tests or console
require 'test/support/docker_helper'

# Start containers
Parse::Test::DockerHelper.start!

# Check if running
Parse::Test::DockerHelper.running?

# View logs
puts Parse::Test::DockerHelper.logs

# Stop containers
Parse::Test::DockerHelper.stop!
```

## Dashboard Access

When using Docker Compose, you can access the Parse Dashboard at:
- URL: http://localhost:4040
- Username: `admin`
- Password: `admin`

## Cloud Code Testing

Sample cloud functions are provided in `test/cloud/main.js`:

```ruby
# Test cloud functions
result = Parse::CloudFunction.call('hello', name: 'World')
assert_equal 'Hello World!', result
```

## Troubleshooting

### Docker Issues

```bash
# Check container status
docker-compose -f docker-compose.test.yml ps

# View Parse Server logs
docker logs parse-stack-test-server

# Reset everything
docker-compose -f docker-compose.test.yml down -v
docker-compose -f docker-compose.test.yml up -d
```

### Master Key Authentication Issues

If you see `Request using master key rejected as the request IP address ... is not set in Parse Server option 'masterKeyIps'`:

1. **Verify the custom image is built**: 
   ```bash
   docker-compose -f docker-compose.test.yml build parse
   ```

2. **Check startup script execution**:
   ```bash
   docker logs parse-stack-test-server | grep "PARSE_SERVER_MASTER_KEY_IPS"
   ```
   Should show: `PARSE_SERVER_MASTER_KEY_IPS: 0.0.0.0/0,::/0`

3. **Test master key directly**:
   ```bash
   curl -X GET \
     -H "X-Parse-Application-Id: myAppId" \
     -H "X-Parse-Master-Key: myMasterKey" \
     http://localhost:1337/parse/schemas
   ```

### Connection Issues

```ruby
# Test connectivity in console
require 'test/support/test_server'
Parse::Test::ServerHelper.setup
Parse::Test::ServerHelper.server_available?
```

### Port Conflicts

If ports 1337, 4040, or 27017 are in use, modify `docker-compose.test.yml`:

```yaml
services:
  parse:
    ports:
      - "1338:1337"  # Use port 1338 instead
```

Then update your environment variables accordingly.

## Production vs Test Differences

The test server configuration includes:
- Relaxed security settings for testing
- Auto-creation of classes
- Verbose logging
- Sample cloud code

**Never use these settings in production!**

## Status

✅ **Working Setup**: This test server configuration has been verified to work with:
- Parse Server 8.2.3
- MongoDB 5.0  
- Master key authentication for schema operations
- Basic CRUD operations via REST API
- Ruby Parse Stack SDK connection
- Cloud Code execution

The setup successfully resolves Parse Server's IP restriction issues that typically prevent master key usage in Docker environments.