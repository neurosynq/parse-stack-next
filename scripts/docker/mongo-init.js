// MongoDB initialization script
// This script runs when the MongoDB container is first created
// It grants the admin user access to the parse database for direct queries

// The admin user needs readWriteAnyDatabase role to access all databases
db = db.getSiblingDB('admin');

// Grant admin user roles needed for all database access
db.grantRolesToUser('admin', [
  { role: 'readWriteAnyDatabase', db: 'admin' },
  { role: 'dbAdminAnyDatabase', db: 'admin' }
]);

// Initialize the parse database
db = db.getSiblingDB('parse');

// Create a placeholder collection to ensure the database exists
db.createCollection('_init');
db.getCollection('_init').drop();

print('MongoDB initialization completed - admin user granted full database access');
