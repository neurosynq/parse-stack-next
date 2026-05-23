#!/bin/sh
set -e

echo "=== Parse Server Startup Script ==="
echo "Setting up environment..."

# Export environment variables for Parse Server
export PARSE_SERVER_MASTER_KEY_IPS="0.0.0.0/0,::/0"
export PARSE_SERVER_APPLICATION_ID="myAppId"
export PARSE_SERVER_MASTER_KEY="myMasterKey"
export PARSE_SERVER_REST_API_KEY="test-rest-key"
export PARSE_SERVER_DATABASE_URI="mongodb://admin:password@mongo:27017/parse?authSource=admin"
export PARSE_SERVER_MOUNT_PATH="/parse"
export PARSE_SERVER_CLOUD="/parse-server/cloud/main.js"
export PARSE_SERVER_LOG_LEVEL="info"
export PARSE_SERVER_ALLOW_CLIENT_CLASS_CREATION="true"

# LiveQuery configuration via environment variables
export PARSE_SERVER_LIVE_QUERY='{"classNames":["Song","Album","User","_User","TestLiveQuery"]}'
export PARSE_SERVER_START_LIVE_QUERY_SERVER="true"

echo "Environment configured:"
echo "  PARSE_SERVER_APPLICATION_ID: $PARSE_SERVER_APPLICATION_ID"
echo "  PARSE_SERVER_LIVE_QUERY: $PARSE_SERVER_LIVE_QUERY"
echo "  PARSE_SERVER_START_LIVE_QUERY_SERVER: $PARSE_SERVER_START_LIVE_QUERY_SERVER"

# Start Parse Server
echo "Starting Parse Server..."
echo "PATH: $PATH"
echo "Looking for parse-server..."
which node
ls -la /parse-server/

# Try different ways to start parse-server
if [ -f "/parse-server/bin/parse-server" ]; then
  echo "Using /parse-server/bin/parse-server"
  exec /parse-server/bin/parse-server
elif [ -f "/usr/src/app/bin/parse-server" ]; then
  echo "Using /usr/src/app/bin/parse-server"
  exec /usr/src/app/bin/parse-server
else
  echo "Trying with node and index.js"
  cd /parse-server
  exec node ./bin/parse-server
fi