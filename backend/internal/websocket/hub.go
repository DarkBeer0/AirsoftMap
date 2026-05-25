package websocket

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/airsoftmap/backend/internal/model"
	"github.com/airsoftmap/backend/internal/repository"
)

// Hub держит активные WS-коннекшены, маршрутизирует пакеты и применяет
// правила видимости на сервере (клиент не получает лишнего).
//
// Кэш members хранится в памяти: пакеты приходят раз в 3с с каждого игрока,
// без кэша мы бы делали SELECT per receiver per packet — на 50 клиентах это
// порядка тысячи qps к БД. Инвалидация явная: на connect (warm), на
// PATCH /members/:uid и на kill/respawn (через InvalidateMember).
type Hub struct {
	mu      sync.RWMutex
	clients map[string]*Client // userID → Client

	members *repository.MembersRepo
	visible MarkerVisibility // плагин-фильтр для marker-пакетов

	cacheMu sync.RWMutex
	cache   map[string]map[string]*model.GameMember // gameID → userID → member

	register   chan *Client
	unregister chan *Client
	broadcast  chan Packet
}

// MarkerVisibility — узкий контракт, чтобы хабу не пришлось импортировать
// service-пакет (и тащить за собой всю бизнес-логику игр).
type MarkerVisibility interface {
	CanSee(receiver *model.GameMember, m *model.Marker) bool
}

type Client struct {
	UserID string
	GameID string
	Conn   *websocket.Conn
	Send   chan []byte
}

type Packet struct {
	Type    string          `json:"type"` // position | marker | kill | respawn | system
	Author  string          `json:"author"`
	GameID  string          `json:"game_id"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Sent    time.Time       `json:"sent"`
}

func NewHub(members *repository.MembersRepo, visible MarkerVisibility) *Hub {
	return &Hub{
		clients:    make(map[string]*Client),
		members:    members,
		visible:    visible,
		cache:      make(map[string]map[string]*model.GameMember),
		register:   make(chan *Client, 32),
		unregister: make(chan *Client, 32),
		broadcast:  make(chan Packet, 256),
	}
}

func (h *Hub) Run() {
	for {
		select {
		case c := <-h.register:
			h.mu.Lock()
			h.clients[c.UserID] = c
			h.mu.Unlock()
		case c := <-h.unregister:
			h.mu.Lock()
			if existing, ok := h.clients[c.UserID]; ok && existing == c {
				delete(h.clients, c.UserID)
				close(c.Send)
			}
			h.mu.Unlock()
		case p := <-h.broadcast:
			h.dispatch(p)
		}
	}
}

// Broadcast — публичный вход для HTTP-хендлеров (например, POST /markers
// после INSERT шлёт пакет всем подходящим клиентам).
func (h *Hub) Broadcast(p Packet) {
	if p.Sent.IsZero() {
		p.Sent = time.Now().UTC()
	}
	select {
	case h.broadcast <- p:
	default:
		// очередь забита — теряем пакет (lossy lazy delivery); пользователь
		// дотянет данные из GET /markers при следующем обновлении.
	}
}

// Serve блокирующе обслуживает один WS-коннекшн. Вызывается из gin-хендлера.
func (h *Hub) Serve(ctx context.Context, conn *websocket.Conn, userID, gameID string) {
	c := &Client{
		UserID: userID,
		GameID: gameID,
		Conn:   conn,
		Send:   make(chan []byte, 32),
	}
	// Прогреваем кэш для текущей игры — чтобы первый же dispatch не дёрнул БД.
	h.warmGame(gameID)

	h.register <- c
	defer func() {
		h.unregister <- c
		_ = conn.Close(websocket.StatusNormalClosure, "")
	}()

	// Writer
	go func() {
		for msg := range c.Send {
			ctx2, cancel := context.WithTimeout(ctx, 5*time.Second)
			_ = conn.Write(ctx2, websocket.MessageText, msg)
			cancel()
		}
	}()

	// Reader
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var p Packet
		if err := json.Unmarshal(data, &p); err != nil {
			continue
		}
		p.Author = userID
		p.GameID = gameID
		p.Sent = time.Now().UTC()

		// Позиции троттлятся и на сервере: пишем в game_members.last_lng/lat,
		// но без блокировки broadcast (асинхронно, ошибки молча).
		if p.Type == "position" {
			h.persistPosition(p)
		}

		h.broadcast <- p
	}
}

func (h *Hub) persistPosition(p Packet) {
	var pos struct {
		Lng float64 `json:"lng"`
		Lat float64 `json:"lat"`
	}
	if err := json.Unmarshal(p.Payload, &pos); err != nil {
		return
	}
	go func() {
		_ = h.members.UpdatePosition(h.members.DB(), p.Author, p.GameID, pos.Lng, pos.Lat)
	}()
}

func (h *Hub) dispatch(p Packet) {
	author := h.cachedMember(p.Author, p.GameID)
	if author == nil {
		return
	}

	var marker *model.Marker
	if p.Type == "marker" && len(p.Payload) > 0 {
		var m model.Marker
		if err := json.Unmarshal(p.Payload, &m); err == nil {
			marker = &m
		}
	}

	h.mu.RLock()
	defer h.mu.RUnlock()
	for uid, c := range h.clients {
		if c.GameID != p.GameID || uid == p.Author {
			continue
		}
		receiver := h.cachedMember(uid, p.GameID)
		if !h.canReceive(receiver, author, marker, p) {
			continue
		}
		bytes, _ := json.Marshal(p)
		select {
		case c.Send <- bytes:
		default:
			// очередь клиента забита — пропускаем (lossy для позиций)
		}
	}
}

// canReceive — серверная фильтрация. Главное правило: убитый не получает
// позиции живых из других сторон (никаких подсказок «с того света»).
func (h *Hub) canReceive(receiver, author *model.GameMember, marker *model.Marker, p Packet) bool {
	if receiver == nil {
		return false
	}
	if receiver.Role == model.RoleOrganizer {
		return true
	}
	switch p.Type {
	case "position":
		if receiver.Status == model.MemberStatusDead {
			return false
		}
		return author.SideID != nil && receiver.SideID != nil && *author.SideID == *receiver.SideID
	case "marker":
		if marker == nil || h.visible == nil {
			return false
		}
		return h.visible.CanSee(receiver, marker)
	case "kill", "respawn":
		// Убит/возродился — союзникам и организатору; противнику не палим.
		return author.SideID != nil && receiver.SideID != nil && *author.SideID == *receiver.SideID
	case "system":
		return true
	}
	return false
}

// ─── Cache ─────────────────────────────────────────────────────────────────

// cachedMember — поднимает member из кэша, при промахе грузит из БД и кладёт
// в кэш. Промахи возможны после ребута сервера или нового join, который не
// успел пройти через WS Serve.
func (h *Hub) cachedMember(userID, gameID string) *model.GameMember {
	h.cacheMu.RLock()
	if game, ok := h.cache[gameID]; ok {
		if m, ok := game[userID]; ok {
			h.cacheMu.RUnlock()
			return m
		}
	}
	h.cacheMu.RUnlock()

	m, err := h.members.ByUserAndGame(h.members.DB(), userID, gameID)
	if err != nil || m == nil {
		return nil
	}
	h.cacheMu.Lock()
	game, ok := h.cache[gameID]
	if !ok {
		game = make(map[string]*model.GameMember)
		h.cache[gameID] = game
	}
	game[userID] = m
	h.cacheMu.Unlock()
	return m
}

// warmGame — массово грузит всех members игры. Дёшево (один SELECT), окупается
// сразу же первым dispatch'ем (нет N запросов по числу получателей).
func (h *Hub) warmGame(gameID string) {
	all, err := h.members.ListByGame(h.members.DB(), gameID)
	if err != nil {
		return
	}
	game := make(map[string]*model.GameMember, len(all))
	for i := range all {
		game[all[i].UserID] = &all[i]
	}
	h.cacheMu.Lock()
	h.cache[gameID] = game
	h.cacheMu.Unlock()
}

// InvalidateMember — выкинуть конкретного игрока из кэша. Вызывают
// PATCH /members/:uid и kill/respawn хендлеры.
func (h *Hub) InvalidateMember(gameID, userID string) {
	h.cacheMu.Lock()
	if game, ok := h.cache[gameID]; ok {
		delete(game, userID)
	}
	h.cacheMu.Unlock()
}

// InvalidateGame — выкинуть всю игру. Сейчас не используется, но пригодится
// при массовых изменениях (например, расформирование стороны).
func (h *Hub) InvalidateGame(gameID string) {
	h.cacheMu.Lock()
	delete(h.cache, gameID)
	h.cacheMu.Unlock()
}
