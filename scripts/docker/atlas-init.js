// Atlas Local initialization script for Atlas Search integration tests
// This script runs after the Atlas Local container is ready
// It seeds test data and creates the Atlas Search index

print("=== Atlas Search Test Setup ===");
print("Database: " + db.getName());

// Clear existing data
print("\n1. Clearing existing data...");
db.Song.drop();

// Insert test data
print("\n2. Inserting test song data...");
const songs = [
  {
    _id: "song1",
    title: "Love Story",
    artist: "Taylor Swift",
    genre: "Pop",
    plays: 5000000,
    _created_at: new Date(),
    _updated_at: new Date()
  },
  {
    _id: "song2",
    title: "Lovely Day",
    artist: "Bill Withers",
    genre: "Soul",
    plays: 3000000,
    _created_at: new Date(),
    _updated_at: new Date()
  },
  {
    _id: "song3",
    title: "Bohemian Rhapsody",
    artist: "Queen",
    genre: "Rock",
    plays: 10000000,
    _created_at: new Date(),
    _updated_at: new Date()
  },
  {
    _id: "song4",
    title: "Rock and Roll",
    artist: "Led Zeppelin",
    genre: "Rock",
    plays: 4000000,
    _created_at: new Date(),
    _updated_at: new Date()
  },
  {
    _id: "song5",
    title: "What Is Love",
    artist: "Haddaway",
    genre: "Dance",
    plays: 2500000,
    _created_at: new Date(),
    _updated_at: new Date()
  },
  {
    _id: "song6",
    title: "I Will Always Love You",
    artist: "Whitney Houston",
    genre: "Pop",
    plays: 8000000,
    _created_at: new Date(),
    _updated_at: new Date()
  },
  {
    _id: "song7",
    title: "Crazy Little Thing Called Love",
    artist: "Queen",
    genre: "Rock",
    plays: 3500000,
    _created_at: new Date(),
    _updated_at: new Date()
  },
  {
    _id: "song8",
    title: "Shape of You",
    artist: "Ed Sheeran",
    genre: "Pop",
    plays: 12000000,
    _created_at: new Date(),
    _updated_at: new Date()
  }
];

db.Song.insertMany(songs);
print("Inserted " + db.Song.countDocuments() + " songs");

// Create Atlas Search index
print("\n3. Creating Atlas Search index...");

// Drop existing search indexes first
try {
  const existingIndexes = db.Song.getSearchIndexes();
  existingIndexes.forEach(function(idx) {
    print("Dropping existing index: " + idx.name);
    db.Song.dropSearchIndex(idx.name);
  });
} catch (e) {
  print("No existing search indexes to drop (or error checking): " + e.message);
}

// Wait a moment for any dropped indexes to be fully removed
sleep(1000);

// Create the search index with autocomplete support
const indexDefinition = {
  mappings: {
    dynamic: true,
    fields: {
      title: [
        {
          type: "string",
          analyzer: "lucene.standard"
        },
        {
          type: "autocomplete",
          analyzer: "lucene.standard",
          tokenization: "edgeGram",
          minGrams: 2,
          maxGrams: 15,
          foldDiacritics: true
        }
      ],
      artist: {
        type: "string",
        analyzer: "lucene.standard"
      },
      genre: [
        {
          type: "string",
          analyzer: "lucene.standard"
        },
        {
          type: "stringFacet"
        }
      ],
      plays: [
        {
          type: "number"
        },
        {
          type: "numberFacet"
        }
      ]
    }
  }
};

try {
  db.Song.createSearchIndex("default", indexDefinition);
  print("Search index 'default' created successfully");
} catch (e) {
  print("Error creating search index: " + e.message);
  // Try alternative method
  try {
    db.runCommand({
      createSearchIndexes: "Song",
      indexes: [{ name: "default", definition: indexDefinition }]
    });
    print("Search index created via runCommand");
  } catch (e2) {
    print("Alternative method also failed: " + e2.message);
  }
}

// Wait for index to become queryable
print("\n4. Waiting for index to become ready...");
let attempts = 0;
const maxAttempts = 30;
let indexReady = false;

while (attempts < maxAttempts && !indexReady) {
  try {
    const indexes = db.Song.getSearchIndexes();
    const defaultIndex = indexes.find(idx => idx.name === "default");
    if (defaultIndex && defaultIndex.queryable === true) {
      indexReady = true;
      print("Index is ready and queryable!");
    } else {
      print("Waiting for index... (attempt " + (attempts + 1) + "/" + maxAttempts + ")");
      sleep(2000);
    }
  } catch (e) {
    print("Error checking index status: " + e.message);
    sleep(2000);
  }
  attempts++;
}

if (!indexReady) {
  print("WARNING: Index may not be ready yet. Tests might fail initially.");
}

// Verify setup
print("\n5. Verification:");
print("   Songs in collection: " + db.Song.countDocuments());

try {
  const searchIndexes = db.Song.getSearchIndexes();
  print("   Search indexes: " + searchIndexes.length);
  searchIndexes.forEach(function(idx) {
    print("     - " + idx.name + " (queryable: " + idx.queryable + ")");
  });
} catch (e) {
  print("   Could not list search indexes: " + e.message);
}

// Test a simple search to verify it works
print("\n6. Testing search...");
try {
  const testResult = db.Song.aggregate([
    { $search: { index: "default", text: { query: "love", path: { wildcard: "*" } } } },
    { $limit: 3 }
  ]).toArray();
  print("   Test search found " + testResult.length + " results for 'love'");
  if (testResult.length > 0) {
    print("   First result: " + testResult[0].title + " by " + testResult[0].artist);
  }
} catch (e) {
  print("   Search test failed (index may still be building): " + e.message);
}

print("\n=== Atlas Search Setup Complete ===\n");
