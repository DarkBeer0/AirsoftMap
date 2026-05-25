package repository

import (
	"database/sql"
	"errors"
	"time"

	"github.com/jmoiron/sqlx"

	"github.com/airsoftmap/backend/internal/model"
)

// ErrNotFound — sentinel для «строки нет». Сервис мапит её в доменную ошибку.
var ErrNotFound = errors.New("not found")

// Querier — общий контракт *sqlx.DB и *sqlx.Tx, чтобы репозитории работали
// и сами по себе, и внутри транзакций.
type Querier interface {
	NamedExec(query string, arg interface{}) (sql.Result, error)
	Get(dest interface{}, query string, args ...interface{}) error
	Select(dest interface{}, query string, args ...interface{}) error
	Exec(query string, args ...interface{}) (sql.Result, error)
}

// --- Games ---

type GamesRepo struct{ db *sqlx.DB }

func NewGamesRepo(db *sqlx.DB) *GamesRepo { return &GamesRepo{db: db} }

func (r *GamesRepo) DB() *sqlx.DB { return r.db }

func (r *GamesRepo) Insert(q Querier, g *model.Game) error {
	_, err := q.NamedExec(`
		INSERT INTO games (
			id, organizer_id, name, join_code,
			bbox_min_lng, bbox_min_lat, bbox_max_lng, bbox_max_lat,
			status
		) VALUES (
			:id, :organizer_id, :name, :join_code,
			:bbox_min_lng, :bbox_min_lat, :bbox_max_lng, :bbox_max_lat,
			:status
		)
	`, g)
	return err
}

func (r *GamesRepo) ByID(q Querier, id string) (*model.Game, error) {
	var g model.Game
	if err := q.Get(&g, `SELECT * FROM games WHERE id = $1`, id); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &g, nil
}

func (r *GamesRepo) ByJoinCode(q Querier, code string) (*model.Game, error) {
	var g model.Game
	if err := q.Get(&g, `SELECT * FROM games WHERE join_code = $1`, code); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &g, nil
}

// UpdateMapPack — выставляет URL пачки и (опц.) перезаписывает bbox.
// nil-поля bbox оставляют текущие значения благодаря COALESCE.
func (r *GamesRepo) UpdateMapPack(
	q Querier,
	gameID, url string,
	minLng, minLat, maxLng, maxLat *float64,
) error {
	_, err := q.Exec(`
		UPDATE games
		SET map_pack_url = $1,
			bbox_min_lng = COALESCE($2, bbox_min_lng),
			bbox_min_lat = COALESCE($3, bbox_min_lat),
			bbox_max_lng = COALESCE($4, bbox_max_lng),
			bbox_max_lat = COALESCE($5, bbox_max_lat)
		WHERE id = $6
	`, url, minLng, minLat, maxLng, maxLat, gameID)
	return err
}

// --- Sides ---

type SidesRepo struct{ db *sqlx.DB }

func NewSidesRepo(db *sqlx.DB) *SidesRepo { return &SidesRepo{db: db} }

func (r *SidesRepo) DB() *sqlx.DB { return r.db }

func (r *SidesRepo) Insert(q Querier, s *model.Side) error {
	_, err := q.NamedExec(`
		INSERT INTO sides (id, game_id, name, color, join_code)
		VALUES (:id, :game_id, :name, :color, :join_code)
	`, s)
	return err
}

func (r *SidesRepo) ByJoinCode(q Querier, code string) (*model.Side, error) {
	var s model.Side
	if err := q.Get(&s, `SELECT * FROM sides WHERE join_code = $1`, code); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &s, nil
}

func (r *SidesRepo) ListByGame(q Querier, gameID string) ([]model.Side, error) {
	var out []model.Side
	if err := q.Select(&out, `SELECT * FROM sides WHERE game_id = $1 ORDER BY name`, gameID); err != nil {
		return nil, err
	}
	return out, nil
}

// --- Squads ---

type SquadsRepo struct{ db *sqlx.DB }

func NewSquadsRepo(db *sqlx.DB) *SquadsRepo { return &SquadsRepo{db: db} }

func (r *SquadsRepo) DB() *sqlx.DB { return r.db }

func (r *SquadsRepo) Insert(q Querier, s *model.Squad) error {
	_, err := q.NamedExec(`
		INSERT INTO squads (id, side_id, name)
		VALUES (:id, :side_id, :name)
	`, s)
	return err
}

func (r *SquadsRepo) ByID(q Querier, id string) (*model.Squad, error) {
	var s model.Squad
	if err := q.Get(&s, `SELECT * FROM squads WHERE id = $1`, id); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &s, nil
}

// ListByGame — все отряды всех сторон игры (с JOIN на sides для фильтра).
func (r *SquadsRepo) ListByGame(q Querier, gameID string) ([]model.Squad, error) {
	var out []model.Squad
	err := q.Select(&out, `
		SELECT sq.* FROM squads sq
		JOIN sides s ON s.id = sq.side_id
		WHERE s.game_id = $1
		ORDER BY sq.name
	`, gameID)
	if err != nil {
		return nil, err
	}
	return out, nil
}

// --- Members ---

type MembersRepo struct{ db *sqlx.DB }

func NewMembersRepo(db *sqlx.DB) *MembersRepo { return &MembersRepo{db: db} }

func (r *MembersRepo) DB() *sqlx.DB { return r.db }

func (r *MembersRepo) ByUserAndGame(q Querier, userID, gameID string) (*model.GameMember, error) {
	var m model.GameMember
	if err := q.Get(&m, `SELECT * FROM game_members WHERE user_id = $1 AND game_id = $2`, userID, gameID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &m, nil
}

func (r *MembersRepo) ListByGame(q Querier, gameID string) ([]model.GameMember, error) {
	var out []model.GameMember
	if err := q.Select(&out, `SELECT * FROM game_members WHERE game_id = $1 ORDER BY callsign`, gameID); err != nil {
		return nil, err
	}
	return out, nil
}

// Upsert по (game_id, user_id). При повторном join обновляем сторону и позывной,
// но НЕ трогаем role/status — иначе организатор, отсканировав QR своей же стороны,
// внезапно станет soldier и потеряет права.
func (r *MembersRepo) Upsert(q Querier, m *model.GameMember) error {
	_, err := q.NamedExec(`
		INSERT INTO game_members (
			id, game_id, user_id, side_id, squad_id, callsign, role, status
		) VALUES (
			:id, :game_id, :user_id, :side_id, :squad_id, :callsign, :role, :status
		)
		ON CONFLICT (game_id, user_id) DO UPDATE
			SET side_id  = EXCLUDED.side_id,
				callsign = EXCLUDED.callsign
	`, m)
	return err
}

func (r *MembersRepo) ByID(q Querier, id string) (*model.GameMember, error) {
	var m model.GameMember
	if err := q.Get(&m, `SELECT * FROM game_members WHERE id = $1`, id); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &m, nil
}

func (r *MembersRepo) UpdateStatus(q Querier, id string, status string) error {
	_, err := q.Exec(`UPDATE game_members SET status = $1 WHERE id = $2`, status, id)
	return err
}

// UpdateStatusAndRespawn — атомарно меняет статус и respawn_until.
// Передача nil в respawnUntil очищает значение (alive после респауна).
func (r *MembersRepo) UpdateStatusAndRespawn(
	q Querier, id, status string, respawnUntil *time.Time,
) error {
	_, err := q.Exec(`
		UPDATE game_members
		SET status = $1, respawn_until = $2
		WHERE id = $3
	`, status, respawnUntil, id)
	return err
}

// UpdateAssignment — изменить сторону / отряд / роль / позывной.
// nil-поля сохраняют текущие значения (COALESCE).
func (r *MembersRepo) UpdateAssignment(
	q Querier,
	id string,
	sideID, squadID *string,
	role, callsign *string,
) error {
	_, err := q.Exec(`
		UPDATE game_members
		SET side_id  = COALESCE($1, side_id),
			squad_id = COALESCE($2, squad_id),
			role     = COALESCE($3, role),
			callsign = COALESCE($4, callsign)
		WHERE id = $5
	`, sideID, squadID, role, callsign, id)
	return err
}

func (r *MembersRepo) UpdatePosition(q Querier, userID, gameID string, lng, lat float64) error {
	_, err := q.Exec(`
		UPDATE game_members
		SET last_lng = $1, last_lat = $2, last_update = NOW()
		WHERE user_id = $3 AND game_id = $4
	`, lng, lat, userID, gameID)
	return err
}

// --- SpawnPoints ---

type SpawnPointsRepo struct{ db *sqlx.DB }

func NewSpawnPointsRepo(db *sqlx.DB) *SpawnPointsRepo { return &SpawnPointsRepo{db: db} }

func (r *SpawnPointsRepo) DB() *sqlx.DB { return r.db }

func (r *SpawnPointsRepo) Insert(q Querier, s *model.SpawnPoint) error {
	_, err := q.NamedExec(`
		INSERT INTO spawn_points (id, game_id, side_id, name, lng, lat, is_base)
		VALUES (:id, :game_id, :side_id, :name, :lng, :lat, :is_base)
	`, s)
	return err
}

func (r *SpawnPointsRepo) ListByGame(q Querier, gameID string) ([]model.SpawnPoint, error) {
	var out []model.SpawnPoint
	if err := q.Select(&out, `SELECT * FROM spawn_points WHERE game_id = $1 ORDER BY name`, gameID); err != nil {
		return nil, err
	}
	return out, nil
}

// --- Markers ---

type MarkersRepo struct{ db *sqlx.DB }

func NewMarkersRepo(db *sqlx.DB) *MarkersRepo { return &MarkersRepo{db: db} }

func (r *MarkersRepo) DB() *sqlx.DB { return r.db }

func (r *MarkersRepo) Insert(q Querier, m *model.Marker) error {
	_, err := q.NamedExec(`
		INSERT INTO markers (
			id, game_id, author_id, kind, visibility,
			side_id, squad_id, lng, lat, label, expires_at
		) VALUES (
			:id, :game_id, :author_id, :kind, :visibility,
			:side_id, :squad_id, :lng, :lat, :label, :expires_at
		)
	`, m)
	return err
}

func (r *MarkersRepo) ListByGame(q Querier, gameID string) ([]model.Marker, error) {
	var out []model.Marker
	if err := q.Select(&out, `SELECT * FROM markers WHERE game_id = $1`, gameID); err != nil {
		return nil, err
	}
	return out, nil
}

// --- Events ---

type EventsRepo struct{ db *sqlx.DB }

func NewEventsRepo(db *sqlx.DB) *EventsRepo { return &EventsRepo{db: db} }

// Insert идемпотентный — id генерится клиентом, дубли игнорируем.
func (r *EventsRepo) Insert(q Querier, e *model.Event) error {
	_, err := q.NamedExec(`
		INSERT INTO events (id, game_id, user_id, type, payload, occurred_at)
		VALUES (:id, :game_id, :user_id, :type, :payload, :occurred_at)
		ON CONFLICT (id) DO NOTHING
	`, e)
	return err
}
