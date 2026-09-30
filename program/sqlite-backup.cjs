// Consistent copy of live SQLite databases using SQLite's online backup API,
// then an integrity check of each copy. Usage: node sqlite-backup.cjs <pairs.json>
// pairs.json = [{ "src": "...", "dst": "..." }, ...]. Prints a JSON result; exit 1 on any failure.
const fs = require('fs');
const path = require('path');

let Database;
try {
  Database = require('better-sqlite3');
} catch {
  Database = require(path.join(__dirname, 'node_modules/@actual-app/sync-server/node_modules/better-sqlite3'));
}

function open(file) {
  try {
    return new Database(file, { readonly: true, fileMustExist: true });
  } catch {
    return new Database(file, { fileMustExist: true });
  }
}

(async () => {
  // Windows PowerShell 5.1 writes UTF-8 with a BOM.
  const pairs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^﻿/, ''));
  const results = [];
  let failed = false;
  for (const { src, dst } of pairs) {
    try {
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      const db = open(src);
      await db.backup(dst);
      db.close();
      const copy = new Database(dst, { readonly: true });
      const integrity = copy.pragma('integrity_check', { simple: true });
      copy.close();
      if (integrity !== 'ok') failed = true;
      results.push({ src, integrity });
    } catch (e) {
      failed = true;
      results.push({ src, error: String(e && e.message ? e.message : e) });
    }
  }
  console.log(JSON.stringify(results));
  process.exit(failed ? 1 : 0);
})();
