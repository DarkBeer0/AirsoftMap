package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
)

// Простой forward-only мигратор. Применяет все *.up.sql из ./migrations
// по алфавиту, фиксирует имена в таблице schema_migrations.
func main() {
	_ = godotenv.Load()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Fatal("DATABASE_URL not set")
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())`); err != nil {
		log.Fatal(err)
	}

	dir := "migrations"
	if d := os.Getenv("MIGRATIONS_DIR"); d != "" {
		dir = d
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		log.Fatalf("read %s: %v", dir, err)
	}

	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".up.sql") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)

	for _, name := range files {
		var exists bool
		if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE name = $1)`, name).Scan(&exists); err != nil {
			log.Fatal(err)
		}
		if exists {
			fmt.Printf("skip %s (applied)\n", name)
			continue
		}
		body, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			log.Fatal(err)
		}
		fmt.Printf("apply %s\n", name)
		tx, err := db.Begin()
		if err != nil {
			log.Fatal(err)
		}
		if _, err := tx.Exec(string(body)); err != nil {
			_ = tx.Rollback()
			log.Fatalf("%s: %v", name, err)
		}
		if _, err := tx.Exec(`INSERT INTO schema_migrations(name) VALUES ($1)`, name); err != nil {
			_ = tx.Rollback()
			log.Fatal(err)
		}
		if err := tx.Commit(); err != nil {
			log.Fatal(err)
		}
	}
	fmt.Println("done")
}
