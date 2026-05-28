package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/middleware"
	"github.com/airsoftmap/backend/internal/service"
	wshub "github.com/airsoftmap/backend/internal/websocket"
)

type EventHandler struct {
	svc *service.EventService
	hub *wshub.Hub
}

func NewEventHandler(s *service.EventService, hub *wshub.Hub) *EventHandler {
	return &EventHandler{svc: s, hub: hub}
}

type eventIDRequest struct {
	EventID string `json:"event_id,omitempty"`
}

type killResponse struct {
	Status       string    `json:"status"`
	RespawnUntil time.Time `json:"respawn_until"`
}

func (h *EventHandler) Kill(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	var req eventIDRequest
	_ = c.ShouldBindJSON(&req) // тело опционально

	res, err := h.svc.Kill(c.Request.Context(), userID, gameID, req.EventID)
	if err != nil {
		writeEventErr(c, err)
		return
	}

	if h.hub != nil {
		h.hub.InvalidateMember(gameID, userID)
		h.broadcastKill(gameID, userID, res.Member.ID, res.Member.SideID, &res.RespawnUntil)
	}

	c.JSON(http.StatusOK, killResponse{
		Status:       string(res.Member.Status),
		RespawnUntil: res.RespawnUntil,
	})
}

type respawnResponse struct {
	Status string `json:"status"`
}

func (h *EventHandler) Respawn(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	var req eventIDRequest
	_ = c.ShouldBindJSON(&req)

	m, err := h.svc.Respawn(c.Request.Context(), userID, gameID, req.EventID)
	if err != nil {
		writeEventErr(c, err)
		return
	}

	if h.hub != nil {
		h.hub.InvalidateMember(gameID, userID)
		h.broadcastRespawn(gameID, userID, m.ID, m.SideID)
	}

	c.JSON(http.StatusOK, respawnResponse{Status: string(m.Status)})
}

// ─── Batch sync (offline outbox) ────────────────────────────────────────────

type syncEventDTO struct {
	ID         string          `json:"id"          binding:"required,uuid"`
	Type       string          `json:"type"        binding:"required,oneof=kill respawn objective_capture"`
	OccurredAt time.Time       `json:"occurred_at" binding:"required"`
	Payload    json.RawMessage `json:"payload,omitempty"`
}

type syncRequest struct {
	Events []syncEventDTO `json:"events" binding:"required,min=1,max=200,dive"`
}

type syncResponse struct {
	Accepted int `json:"accepted"`
}

func (h *EventHandler) Sync(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	var req syncRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	in := make([]service.SyncEventInput, 0, len(req.Events))
	for _, e := range req.Events {
		var payload *string
		if len(e.Payload) > 0 {
			s := string(e.Payload)
			payload = &s
		}
		in = append(in, service.SyncEventInput{
			ID:         e.ID,
			Type:       e.Type,
			OccurredAt: e.OccurredAt,
			Payload:    payload,
		})
	}

	effects, accepted, err := h.svc.SyncBatch(c.Request.Context(), userID, gameID, in)
	if err != nil {
		writeEventErr(c, err)
		return
	}

	// Только при реально применённых эффектах трогаем кэш и WS.
	if h.hub != nil && len(effects) > 0 {
		h.hub.InvalidateMember(gameID, userID)
		for _, ef := range effects {
			switch ef.Type {
			case "kill":
				h.broadcastKill(gameID, userID, ef.Member.ID, ef.Member.SideID, ef.RespawnUntil)
			case "respawn":
				h.broadcastRespawn(gameID, userID, ef.Member.ID, ef.Member.SideID)
			}
		}
	}

	c.JSON(http.StatusOK, syncResponse{Accepted: accepted})
}

// ─── helpers ────────────────────────────────────────────────────────────────

func (h *EventHandler) broadcastKill(gameID, userID, memberID string, sideID *string, respawnUntil *time.Time) {
	payload, _ := json.Marshal(map[string]any{
		"member_id":     memberID,
		"user_id":       userID,
		"side_id":       sideID,
		"respawn_until": respawnUntil,
	})
	h.hub.Broadcast(wshub.Packet{Type: "kill", Author: userID, GameID: gameID, Payload: payload})
}

func (h *EventHandler) broadcastRespawn(gameID, userID, memberID string, sideID *string) {
	payload, _ := json.Marshal(map[string]any{
		"member_id": memberID,
		"user_id":   userID,
		"side_id":   sideID,
	})
	h.hub.Broadcast(wshub.Packet{Type: "respawn", Author: userID, GameID: gameID, Payload: payload})
}

func writeEventErr(c *gin.Context, err error) {
	switch {
	case errors.Is(err, service.ErrForbidden):
		c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this game"})
	case errors.Is(err, service.ErrValidation):
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
	default:
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
	}
}
