package service

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"github.com/airsoftmap/backend/internal/model"
	"github.com/airsoftmap/backend/internal/repository"
)

var (
	ErrInvalidJoinCode = errors.New("invalid join code")
	ErrGameNotFound    = errors.New("game not found")
	ErrValidation      = errors.New("validation")
)

// Алфавит без визуально похожих символов (O/0, I/1, L) — для удобства ввода вручную.
const codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

type SideInput struct {
	Name  string
	Color string
}

type CreateGameInput struct {
	Name        string
	OrganizerID string
	Sides       []SideInput
	BboxMinLng  *float64
	BboxMinLat  *float64
	BboxMaxLng  *float64
	BboxMaxLat  *float64
}

type GameWithSides struct {
	Game  model.Game
	Sides []model.Side
}

type JoinResult struct {
	Game   model.Game
	Side   model.Side
	Member model.GameMember
}

// --- GameService ---

type GameService struct {
	games   *repository.GamesRepo
	sides   *repository.SidesRepo
	members *repository.MembersRepo
}

func NewGameService(g *repository.GamesRepo, s *repository.SidesRepo, m *repository.MembersRepo) *GameService {
	return &GameService{games: g, sides: s, members: m}
}

// Create — игра + стороны + organizer-member, всё в одной транзакции.
// Если организатор оставил bbox пустым, его можно дозаполнить позже (фаза 2).
func (s *GameService) Create(ctx context.Context, in CreateGameInput) (*GameWithSides, error) {
	if strings.TrimSpace(in.Name) == "" {
		return nil, fmt.Errorf("%w: name required", ErrValidation)
	}
	if in.OrganizerID == "" {
		return nil, fmt.Errorf("%w: organizer required", ErrValidation)
	}
	if len(in.Sides) < 1 {
		return nil, fmt.Errorf("%w: at least one side required", ErrValidation)
	}

	tx, err := s.games.DB().Beginx()
	if err != nil {
		return nil, err
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	gameCode, err := uniqueCode(tx, 6, "games", "join_code")
	if err != nil {
		return nil, err
	}

	gameID := uuid.NewString()
	g := &model.Game{
		ID:          gameID,
		OrganizerID: in.OrganizerID,
		Name:        strings.TrimSpace(in.Name),
		JoinCode:    gameCode,
		BboxMinLng:  in.BboxMinLng,
		BboxMinLat:  in.BboxMinLat,
		BboxMaxLng:  in.BboxMaxLng,
		BboxMaxLat:  in.BboxMaxLat,
		Status:      model.GameStatusLobby,
	}
	if err := s.games.Insert(tx, g); err != nil {
		return nil, fmt.Errorf("insert game: %w", err)
	}

	out := make([]model.Side, 0, len(in.Sides))
	for _, si := range in.Sides {
		sideCode, err := uniqueCode(tx, 5, "sides", "join_code")
		if err != nil {
			return nil, err
		}
		jc := sideCode
		side := &model.Side{
			ID:       uuid.NewString(),
			GameID:   gameID,
			Name:     strings.TrimSpace(si.Name),
			Color:    strings.TrimSpace(si.Color),
			JoinCode: &jc,
		}
		if err := s.sides.Insert(tx, side); err != nil {
			return nil, fmt.Errorf("insert side: %w", err)
		}
		out = append(out, *side)
	}

	// Организатор сразу — член игры с ролью organizer, без привязки к стороне.
	organizer := &model.GameMember{
		ID:       uuid.NewString(),
		GameID:   gameID,
		UserID:   in.OrganizerID,
		Callsign: "Organizer",
		Role:     model.RoleOrganizer,
		Status:   model.MemberStatusAlive,
	}
	if err := s.members.Upsert(tx, organizer); err != nil {
		return nil, fmt.Errorf("upsert organizer: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	committed = true
	return &GameWithSides{Game: *g, Sides: out}, nil
}

// JoinBySideCode — игрок сканирует QR стороны → создаём/обновляем member.
// Для уже существующего члена сохраняем role/status, меняем только сторону и позывной
// (см. MembersRepo.Upsert).
func (s *GameService) JoinBySideCode(ctx context.Context, userID, sideCode, callsign string) (*JoinResult, error) {
	sideCode = strings.ToUpper(strings.TrimSpace(sideCode))
	if sideCode == "" {
		return nil, ErrInvalidJoinCode
	}
	if userID == "" {
		return nil, fmt.Errorf("%w: user required", ErrValidation)
	}
	db := s.games.DB()

	side, err := s.sides.ByJoinCode(db, sideCode)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return nil, ErrInvalidJoinCode
		}
		return nil, err
	}
	game, err := s.games.ByID(db, side.GameID)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return nil, ErrGameNotFound
		}
		return nil, err
	}

	callsign = strings.TrimSpace(callsign)
	if callsign == "" {
		// userID — UUID, первые 4 символа достаточны для различения в чате/списке.
		suffix := userID
		if len(suffix) > 4 {
			suffix = suffix[:4]
		}
		callsign = "Player-" + strings.ToUpper(suffix)
	}

	m := &model.GameMember{
		ID:       uuid.NewString(),
		GameID:   game.ID,
		UserID:   userID,
		SideID:   &side.ID,
		Callsign: callsign,
		Role:     model.RoleSoldier,
		Status:   model.MemberStatusAlive,
	}
	if err := s.members.Upsert(db, m); err != nil {
		return nil, fmt.Errorf("upsert member: %w", err)
	}

	// При конфликте в Upsert ID сохраняется старый — перечитываем актуальную запись.
	actual, err := s.members.ByUserAndGame(db, userID, game.ID)
	if err != nil {
		return nil, err
	}
	return &JoinResult{Game: *game, Side: *side, Member: *actual}, nil
}

// uniqueCode — пытается N раз сгенерировать уникальный код в указанной колонке.
// Альтернатива — ловить unique_violation после INSERT, но pre-check дёшев и читаем.
func uniqueCode(q repository.Querier, length int, table, column string) (string, error) {
	for i := 0; i < 8; i++ {
		code, err := genCode(length)
		if err != nil {
			return "", err
		}
		var exists bool
		query := fmt.Sprintf(`SELECT EXISTS(SELECT 1 FROM %s WHERE %s = $1)`, table, column)
		if err := q.Get(&exists, query, code); err != nil {
			return "", err
		}
		if !exists {
			return code, nil
		}
	}
	return "", errors.New("could not generate unique code")
}

func genCode(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	out := make([]byte, n)
	for i := range b {
		out[i] = codeAlphabet[int(b[i])%len(codeAlphabet)]
	}
	return string(out), nil
}

// --- MarkerService ---

type MarkerService struct {
	markers *repository.MarkersRepo
	members *repository.MembersRepo
}

func NewMarkerService(mk *repository.MarkersRepo, mb *repository.MembersRepo) *MarkerService {
	return &MarkerService{markers: mk, members: mb}
}

// CanSee реализует правила видимости меток. Используется и при GET /markers,
// и при WS broadcast (фаза 3).
func (s *MarkerService) CanSee(receiver *model.GameMember, m *model.Marker) bool {
	if receiver == nil {
		return false
	}
	if receiver.Role == model.RoleOrganizer {
		return true
	}
	switch m.Visibility {
	case model.VisibilityAll:
		return true
	case model.VisibilityOrganizers:
		return false
	case model.VisibilitySide:
		return m.SideID != nil && receiver.SideID != nil && *m.SideID == *receiver.SideID
	case model.VisibilitySquad:
		return m.SquadID != nil && receiver.SquadID != nil && *m.SquadID == *receiver.SquadID
	case model.VisibilitySelf:
		return m.AuthorID == receiver.UserID
	}
	return false
}

// --- EventService ---

type EventService struct {
	events  *repository.EventsRepo
	members *repository.MembersRepo
}

func NewEventService(e *repository.EventsRepo, m *repository.MembersRepo) *EventService {
	return &EventService{events: e, members: m}
}

// TODO (фаза 4): Kill, Respawn, Sync (батч).
