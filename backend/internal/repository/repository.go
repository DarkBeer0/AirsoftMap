package repository

import (
	"github.com/jmoiron/sqlx"

	"github.com/airsoftmap/backend/internal/model"
)

// Все репозитории — тонкий слой поверх sqlx. Бизнес-логика живёт в service.
// MVP: метод-заглушки, реальные SQL добавляем по мере фич.

type GamesRepo struct{ db *sqlx.DB }

func NewGamesRepo(db *sqlx.DB) *GamesRepo { return &GamesRepo{db: db} }

// TODO: Create, GetByID, GetByJoinCode, UpdateMapPack, UpdateBbox.
func (r *GamesRepo) ByJoinCode(code string) (*model.Game, error) { return nil, nil }
func (r *GamesRepo) Create(g *model.Game) error                  { return nil }

type MembersRepo struct{ db *sqlx.DB }

func NewMembersRepo(db *sqlx.DB) *MembersRepo { return &MembersRepo{db: db} }

func (r *MembersRepo) ListByGame(gameID string) ([]model.GameMember, error) { return nil, nil }
func (r *MembersRepo) ByUserAndGame(userID, gameID string) (*model.GameMember, error) {
	return nil, nil
}
func (r *MembersRepo) Upsert(m *model.GameMember) error      { return nil }
func (r *MembersRepo) UpdateStatus(id string, status string) error { return nil }
func (r *MembersRepo) UpdatePosition(userID, gameID string, lng, lat float64) error {
	return nil
}

type MarkersRepo struct{ db *sqlx.DB }

func NewMarkersRepo(db *sqlx.DB) *MarkersRepo { return &MarkersRepo{db: db} }

func (r *MarkersRepo) Create(m *model.Marker) error               { return nil }
func (r *MarkersRepo) ListByGame(gameID string) ([]model.Marker, error) { return nil, nil }

type EventsRepo struct{ db *sqlx.DB }

func NewEventsRepo(db *sqlx.DB) *EventsRepo { return &EventsRepo{db: db} }

func (r *EventsRepo) Insert(e *model.Event) error { return nil }
