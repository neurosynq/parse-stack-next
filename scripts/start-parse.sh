#!/bin/sh
set -e

echo "=== Parse Server Startup Script ==="
echo "Setting up environment..."

# Write environment variables to a file for debugging
echo "PARSE_SERVER_MASTER_KEY_IPS=0.0.0.0/0,::/0" >> /tmp/parse-env
echo "Environment file contents:"
cat /tmp/parse-env

# Export the environment variable
export PARSE_SERVER_MASTER_KEY_IPS="0.0.0.0/0,::/0"

# Verify the variable is set
echo "Environment variable check:"
echo "PARSE_SERVER_MASTER_KEY_IPS: $PARSE_SERVER_MASTER_KEY_IPS"

# Start Parse Server
echo "Starting Parse Server..."
echo "PATH: $PATH"
echo "Looking for parse-server..."
which node
ls -la /parse-server/

# Try different ways to start parse-server
if [ -f "/parse-server/bin/parse-server" ]; then
  echo "Using /parse-server/bin/parse-server"
  exec /parse-server/bin/parse-server \
    --appId myAppId \
    --masterKey myMasterKey \
    --restAPIKey test-rest-key \
    --databaseURI mongodb://admin:password@mongo:27017/parse?authSource=admin \
    --mountPath /parse \
    --cloud /parse-server/cloud/main.js \
    --logLevel info \
    --allowClientClassCreation true
elif [ -f "/usr/src/app/bin/parse-server" ]; then
  echo "Using /usr/src/app/bin/parse-server"
  exec /usr/src/app/bin/parse-server \
    --appId myAppId \
    --masterKey myMasterKey \
    --restAPIKey test-rest-key \
    --databaseURI mongodb://admin:password@mongo:27017/parse?authSource=admin \
    --mountPath /parse \
    --cloud /parse-server/cloud/main.js \
    --logLevel info \
    --allowClientClassCreation true
else
  echo "Trying with node and index.js"
  cd /parse-server
  exec node ./bin/parse-server \
    --appId myAppId \
    --masterKey myMasterKey \
    --restAPIKey test-rest-key \
    --databaseURI mongodb://admin:password@mongo:27017/parse?authSource=admin \
    --mountPath /parse \
    --cloud /parse-server/cloud/main.js \
    --logLevel info \
    --allowClientClassCreation true
fi