// In-process analytics adapter for the integration test stack ONLY.
//
// parse-server's default AnalyticsAdapter is a no-op. To round-trip
// Parse.track_event through a real Parse Server REST call AND assert
// what landed inside the server, we install this tiny adapter that
// records every event onto a process-global ring buffer
// (global.__parseTestCapturedAnalytics) and a pair of Cloud functions
// in main.js drain it back to the Ruby integration test.
//
// Adapter contract (parse-server 8.x, lib/Adapters/Analytics/AnalyticsAdapter.js):
//   class AnalyticsAdapter {
//     appOpened(parameters, req) { return Promise.resolve({}); }
//     trackEvent(eventName, parameters, req) { return Promise.resolve({}); }
//   }
//
// The AnalyticsController invokes trackEvent with eventName as the
// first arg (sourced from req.params.eventName) and parameters as the
// JSON body. Errors are swallowed by the controller; the captured
// record is the only signal the test has.
//
// This file is loaded via PARSE_SERVER_ANALYTICS_ADAPTER pointing at
// /parse-server/cloud/analytics-adapter.js (set in
// scripts/docker/docker-compose.test.yml). DO NOT use this adapter in
// any deployed environment — it has no eviction, no persistence, and
// it deliberately exposes raw event payloads back through a Cloud
// function.

// Soft cap on the captured-events buffer. Beyond this, the adapter
// throws so a runaway test that loops track_event without calling
// resetCapturedAnalyticsEvents fails LOUDLY instead of OOMing the
// container. The cap is generous — normal test runs use single-digit
// captures per test — so any cross of this threshold is almost
// certainly a test bug worth catching.
const MAX_CAPTURED_EVENTS = 10000;

module.exports = function buildTestAnalyticsAdapter(options) {
  // Lazily initialize the buffer on the Node global so a hot-reload of
  // this module (parse-server restart inside the same container is the
  // normal case) doesn't drop previously-captured events. Tests reset
  // the buffer explicitly through the resetCapturedAnalyticsEvents
  // Cloud function before every assertion.
  if (!global.__parseTestCapturedAnalytics) {
    global.__parseTestCapturedAnalytics = [];
  }

  function pushBounded(record) {
    if (global.__parseTestCapturedAnalytics.length >= MAX_CAPTURED_EVENTS) {
      throw new Error(
        '[test-analytics-adapter] capture buffer exceeded ' + MAX_CAPTURED_EVENTS +
        ' entries — a test is leaking events. Call resetCapturedAnalyticsEvents ' +
        'between assertions, or scope the buffer per test.'
      );
    }
    global.__parseTestCapturedAnalytics.push(record);
  }

  return {
    trackEvent: function (eventName, parameters, req) {
      pushBounded({
        kind: 'trackEvent',
        eventName: eventName,
        dimensions: parameters || {},
        // The request object carries the auth context; we capture the
        // strings the integration test pins, not the whole `req` (which
        // is large and not JSON-safe).
        installationId: req && req.info ? req.info.installationId : null,
        sessionToken: req && req.info ? req.info.sessionToken : null,
        receivedAt: new Date().toISOString(),
      });
      return Promise.resolve({});
    },
    appOpened: function (parameters, req) {
      pushBounded({
        kind: 'appOpened',
        dimensions: parameters || {},
        installationId: req && req.info ? req.info.installationId : null,
        sessionToken: req && req.info ? req.info.sessionToken : null,
        receivedAt: new Date().toISOString(),
      });
      return Promise.resolve({});
    },
  };
};
