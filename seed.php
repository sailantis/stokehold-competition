<?php
/**
 * Seed the SQLite database every arm reads.
 *
 * The schema is deliberately identical to azera-competition's: the point of this
 * repo is to compare *servers* running one application, so the application data
 * must not differ from the published dataset the numbers are read against.
 *
 * Usage:
 *   php seed.php              # create/reset with 1000 rows
 *   php seed.php --rows=5000  # custom row count
 */

$opts = getopt('', ['rows::']);
$rows = isset($opts['rows']) ? (int) $opts['rows'] : 1000;

$dataDir = __DIR__ . '/data';
$dbFile = $dataDir . '/bench.sqlite';

if (!is_dir($dataDir)) {
    mkdir($dataDir, 0777, true);
}

$pdo = new PDO('sqlite:' . $dbFile);
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

// WAL + busy timeout: several arms read concurrently, and a benchmark that
// measures lock contention instead of server throughput would be meaningless.
$pdo->exec('PRAGMA journal_mode = WAL');
$pdo->exec('PRAGMA busy_timeout = 5000');

$pdo->exec('DROP TABLE IF EXISTS items');
$pdo->exec(<<<SQL
CREATE TABLE items (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    title      TEXT    NOT NULL,
    created_at TEXT    NOT NULL
)
SQL);

$stmt = $pdo->prepare('INSERT INTO items (title, created_at) VALUES (?, ?)');
$now = date('Y-m-d H:i:s');

$pdo->beginTransaction();
for ($i = 1; $i <= $rows; $i++) {
    $stmt->execute([sprintf('Benchmark Item %05d', $i), $now]);
}
$pdo->commit();

$count = (int) $pdo->query('SELECT COUNT(*) FROM items')->fetchColumn();

echo "Seeded {$count} rows into {$dbFile}\n";
