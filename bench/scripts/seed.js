// Seeds a repeatable dataset sized by its on-disk footprint.
// Usage: SEED_TARGET_MB=1500 mongosh --port 27018 --quiet --file seed.js
//
// The payload is sliced from a random pool, so it does not compress well.
// Inserting continues until the collection's on-disk storageSize reaches the
// target, which keeps the benchmark independent of WiredTiger compression.

const targetBytes = Number(process.env.SEED_TARGET_MB || 1500) * 1024 * 1024;
const batchSize = 1000;
const docSize = 1024;
const poolSize = 4 * 1024 * 1024;

const bench = db.getSiblingDB("bench");
const data = bench.getCollection("data");
const load = bench.getCollection("load");

function storageSize(coll) {
  try {
    return coll.stats().storageSize;
  } catch (e) {
    return 0; // collection does not exist yet
  }
}

if (!bench.getCollectionNames().includes("data")) {
  bench.createCollection("data");
}

function randomHex(len) {
  let s = "";
  while (s.length < len) {
    s += Math.floor(Math.random() * 0x100000000).toString(16).padStart(8, "0");
  }
  return s.slice(0, len);
}

const pool = randomHex(poolSize);

function payload() {
  const off = Math.floor(Math.random() * (pool.length - docSize));
  return pool.slice(off, off + docSize);
}

if (load.estimatedDocumentCount() === 0) {
  const docs = [];
  for (let i = 0; i < 10000; i++) {
    docs.push({ _id: i, v: 0, pad: randomHex(256) });
  }
  load.insertMany(docs);
  print("load collection seeded: " + load.estimatedDocumentCount() + " docs");
}

let count = data.estimatedDocumentCount();
if (count === 0) {
  print("seeding data collection to " + (targetBytes / 1024 / 1024) + " MiB on disk");
}

let lastReport = Date.now();
while (true) {
  const stats = storageSize(data);
  if (stats >= targetBytes) {
    print("target reached: storageSize=" + stats + " bytes, docs=" + count);
    break;
  }

  const docs = [];
  for (let i = 0; i < batchSize; i++) {
    docs.push({ _id: count + i, payload: payload() });
  }
  data.insertMany(docs, { ordered: false });
  count += batchSize;

  if (Date.now() - lastReport > 5000) {
    print("inserted=" + count + " storageSize=" + storageSize(data));
    lastReport = Date.now();
  }
}

print("seed done: docs=" + data.estimatedDocumentCount());
