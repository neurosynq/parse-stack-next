'use strict';

// Test-only push adapter for the parse-stack-next integration stack.
//
// Parse Server's `POST /parse/push` endpoint requires a push adapter to be
// configured; without one it returns code 115 "Missing push configuration".
// This adapter does NOT deliver to any real device gateway (no FCM/APNS
// credentials, no network). It accepts every installation and reports a
// successful transmission, which lets Parse Server create and complete a real
// `_PushStatus` row. That makes the push *send + status lifecycle* testable
// deterministically and offline.
//
// Wired via PARSE_SERVER_PUSH in scripts/start-parse.sh. Do NOT ship this in a
// deployed environment — it silently drops every notification.
class DummyPushAdapter {
  constructor(options = {}) {
    this.options = options;
    // Device types this adapter claims to handle. Installations with other
    // types are skipped by Parse Server before send() is called.
    this.validPushTypes = ['ios', 'android'];
  }

  // Parse Server calls this with the push body and the matched installations.
  // Return one result per installation. `transmitted: true` is tallied under
  // numSent / sentPerType for that deviceType; `transmitted: false` under
  // numFailed / failedPerType.
  //
  // Failure simulation (test hook): any installation whose deviceToken begins
  // with "fail-" is reported as a failed transmission. This lets tests exercise
  // the failure half of the _PushStatus lifecycle (numFailed, failedPerType,
  // and mixed sent+failed pushes) deterministically and offline.
  send(body, installations) {
    const results = installations.map((installation) => {
      const token = installation.deviceToken || '';
      const failed = token.indexOf('fail-') === 0;
      const result = {
        transmitted: !failed,
        device: {
          deviceToken: installation.deviceToken,
          deviceType: installation.deviceType,
        },
      };
      if (failed) {
        result.response = { error: 'simulated-failure' };
      }
      return result;
    });
    return Promise.resolve(results);
  }

  getValidPushTypes() {
    return this.validPushTypes;
  }
}

module.exports = DummyPushAdapter;
module.exports.default = DummyPushAdapter;
