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
// правила видимости (на сервере, чтобы клиент не получал лишнего).
type Hub struct {
	mu      sync.RWMutex
	clients map[string]*Client // userID → Client
	members *repository.MembersRepo

	register   chan *Client
	unregister chan *Client
	broadcast  chan Packet
}

type Client struct {
	UserID string
	GameID string
	Conn   *websocket.Conn
	Send   chan []byte
}

type Packet struct {
	Type     string          `json:"type"` // position | marker | kill | respawn | system
	Author   string          `json:"author"`
	GameID   string          `json:"game_id"`
	Payload  json.RawMessage `json:"payload,omitempty"`
	Sent     time.Time       `json:"sent"`
}

func NewHub(members *repository.MembersRepo) *Hub {
	return &Hub{
		clients:    make(map[string]*Client),
		members:    members,
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

// Serve блокирующе обслуживает один WS-коннекшн. Вызывается из gin-хендлера.
func (h *Hub) Serve(ctx context.Context, conn *websocket.Conn, userID, gameID string) {
	c := &Client{
		UserID: userID,
		GameID: gameID,
		Conn:   conn,
		Send:   make(chan []byte, 32),
	}
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
		// TODO: для type=position → MembersRepo.UpdatePosition (троттлится сервером тоже)
		h.broadcast <- p
	}
}

func (h *Hub) dispatch(p Packet) {
	// Получаем автора пакета (для фильтрации по стороне/отряду).
	author, _ := h.members.ByUserAndGame(p.Author, p.GameID)
	if author == nil {
		return
	}

	h.mu.RLock()
	defer h.mu.RUnlock()
	for uid, c := range h.clients {
		if c.GameID != p.GameID || uid == p.Author {
			continue
		}
		receiver, _ := h.members.ByUserAndGame(uid, p.GameID)
		if !canReceive(receiver, author, p) {
			continue
		}
		bytes, _ := json.Marshal(p)
		select {
		case c.Send <- bytes:
		default:
			// очередь забита — пропускаем (lossy для позиций)
		}
	}
}

// canReceive — серверная фильтрация. Главное правило: убитый не получает
// позиции живых из других сторон (никаких подсказок «с того света»).
func canReceive(receiver, author *model.GameMember, p Packet) bool {
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
		// TODO: использовать MarkerService.CanSee — нужно достать сам marker по id из payload.
		return true
	case "kill", "respawn", "system":
		return true
	}
	return false
}
