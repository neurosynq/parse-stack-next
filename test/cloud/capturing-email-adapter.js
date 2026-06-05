'use strict';

// Test-only email adapter for the parse-stack-next integration stack.
//
// Parse Server requires an email adapter (and a public server URL) before
// `POST /requestPasswordReset` / `requestVerificationEmail` will do anything.
// This adapter does NOT send real email. Instead it captures each outgoing
// message into an `EmailCapture` class via the local REST API (master key), so
// integration tests can assert that an email was generated and read back the
// reset / verification link. DO NOT use this in a deployed environment — it
// silently swallows every email and records reset links in plaintext.
//
// Wired via PARSE_SERVER_EMAIL_ADAPTER in scripts/start-parse.sh.

const APP_ID = process.env.PARSE_SERVER_APPLICATION_ID;
const MASTER_KEY = process.env.PARSE_SERVER_MASTER_KEY;
const MOUNT = process.env.PARSE_SERVER_MOUNT_PATH || '/parse';
const BASE = `http://127.0.0.1:1337${MOUNT}`;

async function capture(doc) {
  try {
    await fetch(`${BASE}/classes/EmailCapture`, {
      method: 'POST',
      headers: {
        'X-Parse-Application-Id': APP_ID,
        'X-Parse-Master-Key': MASTER_KEY,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(doc),
    });
  } catch (e) {
    // Test-only: a capture failure must never break the request under test.
    // eslint-disable-next-line no-console
    console.warn('[capturing-email-adapter] capture failed:', e && e.message);
  }
}

class CapturingEmailAdapter {
  constructor(options = {}) {
    this.options = options;
  }

  sendPasswordResetEmail({ link, appName, user }) {
    return capture({
      kind: 'passwordReset',
      email: user && user.get('email'),
      username: user && user.get('username'),
      link,
      appName,
    });
  }

  sendVerificationEmail({ link, appName, user }) {
    return capture({
      kind: 'verification',
      email: user && user.get('email'),
      username: user && user.get('username'),
      link,
      appName,
    });
  }

  sendMail({ to, subject, text }) {
    return capture({ kind: 'mail', email: to, subject, text });
  }
}

module.exports = CapturingEmailAdapter;
module.exports.default = CapturingEmailAdapter;
