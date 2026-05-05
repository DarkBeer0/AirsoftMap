package service

import (
	"github.com/airsoftmap/backend/internal/model"
	"github.com/airsoftmap/backend/internal/repository"
)

type GameService struct {
	games   *repository.GamesRepo
	members *repository.MembersRepo
}

func NewGameService(g *repository.GamesRepo, m *repository.MembersRepo) *GameService {
	return &GameService{games: g, members: m}
}

// TODO: Create, JoinByCode (генерит callsign, создаёт member со status=alive, role=soldier),
// UpdateBbox, AssignSquad, AssignRole, GenerateQR.

type MarkerService struct {
	markers *repository.MarkersRepo
	members *repository.MembersRepo
}

func NewMarkerService(mk *repository.MarkersRepo, mb *repository.MembersRepo) *MarkerService {
	return &MarkerService{markers: mk, members: mb}
}

// CanSee реализует правила видимости меток. Используется и при GET /markers,
// и при WS broadcast.
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

type EventService struct {
	events  *repository.EventsRepo
	members *repository.MembersRepo
}

func NewEventService(e *repository.EventsRepo, m *repository.MembersRepo) *EventService {
	return &EventService{events: e, members: m}
}

// TODO: Kill (member→dead, фиксируем event, при WS-фильтрации dead игнорируется),
// Respawn (member→alive, спавн на ближайшей точке).
