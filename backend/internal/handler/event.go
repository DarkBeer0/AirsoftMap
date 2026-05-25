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
	res, err := h.svc.Kill(c.Request.Context(), userID, gameID)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrForbidden):
			c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this game"})
		case errors.Is(err, service.ErrValidation):
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		}
		return
	}

	// Сбросить кэш членства в WS — теперь статус dead, фильтр позиций должен
	// учитывать это сразу же (живые перестают слать ему позиции врагов).
	if h.hub != nil {
		h.hub.InvalidateMember(gameID, userID)
		payload, _ := json.Marshal(map[string]any{
			"member_id":     res.Member.ID,
			"user_id":       res.Member.UserID,
			"side_id":       res.Member.SideID,
			"respawn_until": res.RespawnUntil,
		})
		h.hub.Broadcast(wshub.Packet{
			Type: "kill", Author: userID, GameID: gameID, Payload: payload,
		})
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
	m, err := h.svc.Respawn(c.Request.Context(), userID, gameID)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrForbidden):
			c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this game"})
		case errors.Is(err, service.ErrValidation):
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		}
		return
	}

	if h.hub != nil {
		h.hub.InvalidateMember(gameID, userID)
		payload, _ := json.Marshal(map[string]any{
			"member_id": m.ID,
			"user_id":   m.UserID,
			"side_id":   m.SideID,
		})
		h.hub.Broadcast(wshub.Packet{
			Type: "respawn", Author: userID, GameID: gameID, Payload: payload,
		})
	}

	c.JSON(http.StatusOK, respawnResponse{Status: string(m.Status)})
}
