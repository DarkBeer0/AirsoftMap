package service

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/airsoftmap/backend/internal/model"
	"github.com/airsoftmap/backend/internal/repository"
)

var (
	ErrInvalidJoinCode = errors.New("invalid join code")
	ErrGameNotFound    = errors.New("game not found")
	ErrForbidden       = errors.New("forbidden")
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
	squads  *repository.SquadsRepo
	members *repository.MembersRepo
}

func NewGameService(
	g *repository.GamesRepo,
	s *repository.SidesRepo,
	sq *repository.SquadsRepo,
	m *repository.MembersRepo,
) *GameService {
	return &GameService{games: g, sides: s, squads: sq, members: m}
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

type SetMapPackInput struct {
	UserID     string
	GameID     string
	MapPackURL string
	BboxMinLng *float64
	BboxMinLat *float64
	BboxMaxLng *float64
	BboxMaxLat *float64
}

// SetMapPack — записать URL .mbtiles в Storage и (опц.) обновить bbox.
// Доступно только организатору игры.
func (s *GameService) SetMapPack(ctx context.Context, in SetMapPackInput) error {
	if in.GameID == "" || in.MapPackURL == "" {
		return fmt.Errorf("%w: game_id and map_pack_url required", ErrValidation)
	}
	db := s.games.DB()

	member, err := s.members.ByUserAndGame(db, in.UserID, in.GameID)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return ErrForbidden
		}
		return err
	}
	if member.Role != model.RoleOrganizer {
		return ErrForbidden
	}
	return s.games.UpdateMapPack(
		db, in.GameID, in.MapPackURL,
		in.BboxMinLng, in.BboxMinLat, in.BboxMaxLng, in.BboxMaxLat,
	)
}

// ListMembers — список участников игры с учётом прав:
//   - organizer / side_commander → видят всех;
//   - squad_leader / soldier      → только свою сторону (включая себя).
//
// Если запрашивающий не член игры — ErrForbidden (а не 404, чтобы не палить
// существование игры по чужому id).
func (s *GameService) ListMembers(ctx context.Context, userID, gameID string) ([]model.GameMember, error) {
	if gameID == "" || userID == "" {
		return nil, fmt.Errorf("%w: missing ids", ErrValidation)
	}
	db := s.games.DB()

	self, err := s.members.ByUserAndGame(db, userID, gameID)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return nil, ErrForbidden
		}
		return nil, err
	}

	all, err := s.members.ListByGame(db, gameID)
	if err != nil {
		return nil, err
	}

	if self.Role == model.RoleOrganizer || self.Role == model.RoleSideCommander {
		return all, nil
	}
	if self.SideID == nil {
		// Игрок ещё не на стороне — видит только себя.
		return []model.GameMember{*self}, nil
	}
	out := make([]model.GameMember, 0, len(all))
	for _, m := range all {
		if m.SideID != nil && *m.SideID == *self.SideID {
			out = append(out, m)
		}
	}
	return out, nil
}

// ─── Sides / Squads / Member assignment ────────────────────────────────────

// ListSides — доступно любому члену игры; для не-членов 403 (а не 404,
// чтобы не палить существование игры по id).
func (s *GameService) ListSides(ctx context.Context, userID, gameID string) ([]model.Side, error) {
	if gameID == "" || userID == "" {
		return nil, fmt.Errorf("%w: missing ids", ErrValidation)
	}
	db := s.games.DB()
	if _, err := s.requireMember(db, userID, gameID); err != nil {
		return nil, err
	}
	return s.sides.ListByGame(db, gameID)
}

// ListSquads — все отряды всех сторон игры. Доступно любому члену.
// Фильтрацию по стороне делает клиент (организатор видит всё).
func (s *GameService) ListSquads(ctx context.Context, userID, gameID string) ([]model.Squad, error) {
	if gameID == "" || userID == "" {
		return nil, fmt.Errorf("%w: missing ids", ErrValidation)
	}
	db := s.games.DB()
	if _, err := s.requireMember(db, userID, gameID); err != nil {
		return nil, err
	}
	return s.squads.ListByGame(db, gameID)
}

type CreateSquadInput struct {
	UserID string
	GameID string
	SideID string
	Name   string
}

// CreateSquad — organizer может создать в любой стороне; side_commander —
// только в своей. Squad_leader/soldier — нет.
func (s *GameService) CreateSquad(ctx context.Context, in CreateSquadInput) (*model.Squad, error) {
	if strings.TrimSpace(in.Name) == "" || in.SideID == "" {
		return nil, fmt.Errorf("%w: name and side required", ErrValidation)
	}
	db := s.games.DB()
	caller, err := s.requireMember(db, in.UserID, in.GameID)
	if err != nil {
		return nil, err
	}
	side, err := s.sideInGame(db, in.SideID, in.GameID)
	if err != nil {
		return nil, err
	}
	if !canManageSide(caller, side) {
		return nil, ErrForbidden
	}
	sq := &model.Squad{
		ID:     uuid.NewString(),
		SideID: in.SideID,
		Name:   strings.TrimSpace(in.Name),
	}
	if err := s.squads.Insert(db, sq); err != nil {
		return nil, err
	}
	return sq, nil
}

type UpdateMemberInput struct {
	CallerID string
	GameID   string
	MemberID string

	// Все опциональные — обновляются только переданные поля.
	SideID   *string
	SquadID  *string
	Role     *string
	Callsign *string
}

// UpdateMember — назначение стороны/отряда/роли/позывного.
//
// Правила:
//   - organizer: может всё, кроме понижения себя.
//   - side_commander: только члены его стороны; нельзя выдать organizer-роль;
//     нельзя перевести бойца в другую сторону (это решает organizer).
//   - остальные роли — 403.
//
// Если назначается squad_id — проверяем, что отряд принадлежит стороне,
// в которой числится (или будет числиться) член.
func (s *GameService) UpdateMember(ctx context.Context, in UpdateMemberInput) (*model.GameMember, error) {
	if in.GameID == "" || in.MemberID == "" {
		return nil, fmt.Errorf("%w: missing ids", ErrValidation)
	}
	db := s.games.DB()
	caller, err := s.requireMember(db, in.CallerID, in.GameID)
	if err != nil {
		return nil, err
	}

	target, err := s.members.ByID(db, in.MemberID)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return nil, ErrForbidden
		}
		return nil, err
	}
	if target.GameID != in.GameID {
		return nil, ErrForbidden
	}

	if err := s.authorizeMemberUpdate(caller, target, in); err != nil {
		return nil, err
	}

	// Если назначается squad — он должен принадлежать целевой стороне.
	if in.SquadID != nil && *in.SquadID != "" {
		sq, err := s.squads.ByID(db, *in.SquadID)
		if err != nil {
			return nil, fmt.Errorf("%w: squad not found", ErrValidation)
		}
		// Сторона, в которой член будет числиться после апдейта.
		effectiveSide := target.SideID
		if in.SideID != nil {
			effectiveSide = in.SideID
		}
		if effectiveSide == nil || sq.SideID != *effectiveSide {
			return nil, fmt.Errorf("%w: squad belongs to different side", ErrValidation)
		}
	}

	if err := s.members.UpdateAssignment(
		db, in.MemberID,
		in.SideID, in.SquadID, in.Role, in.Callsign,
	); err != nil {
		return nil, err
	}
	return s.members.ByID(db, in.MemberID)
}

func (s *GameService) authorizeMemberUpdate(
	caller, target *model.GameMember,
	in UpdateMemberInput,
) error {
	// Запрещено понижать самого себя (защита от случайного «развыдачи» organizer'а).
	if caller.UserID == target.UserID && in.Role != nil && *in.Role != string(caller.Role) {
		return fmt.Errorf("%w: cannot change own role", ErrForbidden)
	}

	switch caller.Role {
	case model.RoleOrganizer:
		return nil
	case model.RoleSideCommander:
		// Только своя сторона; нельзя выдавать organizer; нельзя менять сторону.
		if caller.SideID == nil || target.SideID == nil || *caller.SideID != *target.SideID {
			return ErrForbidden
		}
		if in.SideID != nil && (target.SideID == nil || *in.SideID != *target.SideID) {
			return ErrForbidden
		}
		if in.Role != nil && *in.Role == string(model.RoleOrganizer) {
			return ErrForbidden
		}
		return nil
	default:
		return ErrForbidden
	}
}

func (s *GameService) requireMember(
	q repository.Querier, userID, gameID string,
) (*model.GameMember, error) {
	m, err := s.members.ByUserAndGame(q, userID, gameID)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return nil, ErrForbidden
		}
		return nil, err
	}
	return m, nil
}

func (s *GameService) sideInGame(
	q repository.Querier, sideID, gameID string,
) (*model.Side, error) {
	sides, err := s.sides.ListByGame(q, gameID)
	if err != nil {
		return nil, err
	}
	for i := range sides {
		if sides[i].ID == sideID {
			return &sides[i], nil
		}
	}
	return nil, fmt.Errorf("%w: side not in game", ErrValidation)
}

func canManageSide(caller *model.GameMember, side *model.Side) bool {
	if caller.Role == model.RoleOrganizer {
		return true
	}
	if caller.Role == model.RoleSideCommander &&
		caller.SideID != nil && *caller.SideID == side.ID {
		return true
	}
	return false
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
	games   *repository.GamesRepo
	squads  *repository.SquadsRepo
}

func NewMarkerService(
	mk *repository.MarkersRepo,
	mb *repository.MembersRepo,
	g *repository.GamesRepo,
	sq *repository.SquadsRepo,
) *MarkerService {
	return &MarkerService{markers: mk, members: mb, games: g, squads: sq}
}

// CanSee реализует правила видимости меток. Используется и при GET /markers,
// и при WS broadcast.
//
// Особый случай: автор всегда видит свою метку (даже visibility=organizers),
// иначе организатор поставит «для других организаторов» и собственная же
// метка для него пропадёт.
func (s *MarkerService) CanSee(receiver *model.GameMember, m *model.Marker) bool {
	if receiver == nil {
		return false
	}
	if receiver.UserID == m.AuthorID {
		return true
	}
	if receiver.Role == model.RoleOrganizer {
		return true
	}
	switch m.Visibility {
	case model.VisibilityAll:
		return true
	case model.VisibilityOrganizers:
		return false // organizer уже отфильтрован выше
	case model.VisibilitySide:
		return m.SideID != nil && receiver.SideID != nil && *m.SideID == *receiver.SideID
	case model.VisibilitySquad:
		return m.SquadID != nil && receiver.SquadID != nil && *m.SquadID == *receiver.SquadID
	case model.VisibilitySelf:
		return false // только автор, уже отфильтровано выше
	}
	return false
}

type CreateMarkerInput struct {
	UserID     string
	GameID     string
	Kind       string
	Visibility model.Visibility
	Lng        float64
	Lat        float64
	Label      *string
	ExpiresAt  *time.Time
}

// Create — валидирует автора и его права на visibility, проверяет, что точка
// внутри bbox игры (если bbox задан — D1), INSERT.
//
// Возвращает marker для последующего broadcast хендлером.
func (s *MarkerService) Create(ctx context.Context, in CreateMarkerInput) (*model.Marker, error) {
	if in.GameID == "" {
		return nil, fmt.Errorf("%w: game required", ErrValidation)
	}
	kind := strings.TrimSpace(in.Kind)
	if kind == "" {
		return nil, fmt.Errorf("%w: kind required", ErrValidation)
	}
	if !validVisibility(in.Visibility) {
		return nil, fmt.Errorf("%w: bad visibility", ErrValidation)
	}
	if !validLngLat(in.Lng, in.Lat) {
		return nil, fmt.Errorf("%w: coords out of range", ErrValidation)
	}

	db := s.markers.DB()

	author, err := s.members.ByUserAndGame(db, in.UserID, in.GameID)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return nil, ErrForbidden
		}
		return nil, err
	}

	// Bbox-проверка: если организатор задал полигон, метки за его пределами
	// — мисклик/баг карты. Без bbox пропускаем (например, до загрузки тайл-пака).
	game, err := s.games.ByID(db, in.GameID)
	if err != nil {
		return nil, err
	}
	if game.BboxMinLng != nil && game.BboxMinLat != nil &&
		game.BboxMaxLng != nil && game.BboxMaxLat != nil {
		if in.Lng < *game.BboxMinLng || in.Lng > *game.BboxMaxLng ||
			in.Lat < *game.BboxMinLat || in.Lat > *game.BboxMaxLat {
			return nil, fmt.Errorf("%w: marker outside game bbox", ErrValidation)
		}
	}

	// visibility=organizers разрешена только organizer'у (иначе боец сможет
	// слать втихую сообщения в админский слой).
	if in.Visibility == model.VisibilityOrganizers && author.Role != model.RoleOrganizer {
		return nil, ErrForbidden
	}

	// Side/squad подставляем из автора (клиент их не указывает — это серверная
	// истина: метка «для своей стороны» = стороны автора).
	m := &model.Marker{
		ID:         uuid.NewString(),
		GameID:     in.GameID,
		AuthorID:   in.UserID,
		Kind:       kind,
		Visibility: in.Visibility,
		Lng:        in.Lng,
		Lat:        in.Lat,
		Label:      in.Label,
		ExpiresAt:  in.ExpiresAt,
	}
	if in.Visibility == model.VisibilitySide || in.Visibility == model.VisibilitySquad {
		m.SideID = author.SideID
	}
	if in.Visibility == model.VisibilitySquad {
		m.SquadID = author.SquadID
	}

	if err := s.markers.Insert(db, m); err != nil {
		return nil, err
	}
	return m, nil
}

// List — возвращает только видимые текущему userID метки. Не-член игры → 403.
func (s *MarkerService) List(ctx context.Context, userID, gameID string) ([]model.Marker, error) {
	if gameID == "" || userID == "" {
		return nil, fmt.Errorf("%w: missing ids", ErrValidation)
	}
	db := s.markers.DB()

	self, err := s.members.ByUserAndGame(db, userID, gameID)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return nil, ErrForbidden
		}
		return nil, err
	}
	all, err := s.markers.ListByGame(db, gameID)
	if err != nil {
		return nil, err
	}
	out := make([]model.Marker, 0, len(all))
	now := time.Now()
	for i := range all {
		m := all[i]
		if m.ExpiresAt != nil && m.ExpiresAt.Before(now) {
			continue
		}
		if s.CanSee(self, &m) {
			out = append(out, m)
		}
	}
	return out, nil
}

func validVisibility(v model.Visibility) bool {
	switch v {
	case model.VisibilitySelf, model.VisibilitySquad, model.VisibilitySide,
		model.VisibilityOrganizers, model.VisibilityAll:
		return true
	}
	return false
}

func validLngLat(lng, lat float64) bool {
	return lng >= -180 && lng <= 180 && lat >= -90 && lat <= 90
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
