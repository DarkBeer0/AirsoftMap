package repository

import (
	"database/sql"
	"errors"

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

func (r *MembersRepo) UpdateStatus(q Querier, id string, status string) error {
	_, err := q.Exec(`UPDATE game_members SET status = $1 WHERE id = $2`, status, id)
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

// --- Markers ---

type MarkersRepo struct{ db *sqlx.DB }

func NewMarkersRepo(db *sqlx.DB) *MarkersRepo { return &MarkersRepo{db: db} }

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
