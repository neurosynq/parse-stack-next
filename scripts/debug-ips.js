#!/usr/bin/env node

// Debug script to check Parse Server IP configuration
console.log('=== Parse Server IP Debug ===');
console.log('Environment variables:');
console.log('PARSE_SERVER_MASTER_KEY_IPS:', process.env.PARSE_SERVER_MASTER_KEY_IPS);

// Try to load the config file
try {
  const fs = require('fs');
  const config = JSON.parse(fs.readFileSync('/parse-server/config/parse-config.json', 'utf8'));
  console.log('\nConfig file masterKeyIps:', config.masterKeyIps);
} catch (e) {
  console.log('\nConfig file error:', e.message);
}

// Check what Parse Server would use as default
const defaultIps = ['127.0.0.1', '::1'];
console.log('\nDefault masterKeyIps:', defaultIps);

// Test IP parsing
const envIps = process.env.PARSE_SERVER_MASTER_KEY_IPS;
if (envIps) {
  const parsedIps = envIps.split(',');
  console.log('\nParsed environment IPs:', parsedIps);
  
  const net = require('net');
  parsedIps.forEach(ip => {
    const cleanIp = ip.includes('/') ? ip.split('/')[0] : ip;
    console.log(`IP "${ip}" -> clean: "${cleanIp}" -> isIP: ${net.isIP(cleanIp)}`);
  });
}

console.log('\nRequest IP that Parse Server sees: (this would be logged in Parse Server)');
console.log('Expected request IP: 172.18.0.1 (Docker container network)');