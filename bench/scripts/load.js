// Runs a steady read/update workload and prints one JSON line per second:
// {"ts":<ms>,"ops":<n>,"p50":<ms>,"p95":<ms>,"p99":<ms>}
// Usage: LOAD_SECONDS=900 mongosh --port 27018 --quiet --file load.js

const durationSec = Number(process.env.LOAD_SECONDS || 900);
const bench = db.getSiblingDB("bench");
const coll = bench.getCollection("load");
const now = typeof performance !== "undefined" ? () => performance.now() : () => Date.now();
const started = Date.now();

while (Date.now() - started < durationSec * 1000) {
  const lat = [];
  let errors = 0;
  const bucket = now();

  while (now() - bucket < 1000) {
    const id = Math.floor(Math.random() * 10000);
    const t = now();
    try {
      if (Math.random() < 0.8) {
        coll.findOne({ _id: id });
      } else {
        coll.updateOne({ _id: id }, { $inc: { v: 1 } });
      }
    } catch (e) {
      // Tolerate transient connection errors, e.g. while mongod restarts.
      errors++;
      sleep(200);
    }
    lat.push(now() - t);
  }

  lat.sort((a, b) => a - b);
  const q = (p) => lat[Math.min(lat.length - 1, Math.floor(p * lat.length))];

  print(JSON.stringify({
    ts: Date.now(),
    ops: lat.length - errors,
    errors: errors,
    p50: q(0.5),
    p95: q(0.95),
    p99: q(0.99),
  }));
}
