package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/middleware"
	"github.com/airsoftmap/backend/internal/model"
	"github.com/airsoftmap/backend/internal/service"
	wshub "github.com/airsoftmap/backend/internal/websocket"
)

type MarkerHandler struct {
	svc *service.MarkerService
	hub *wshub.Hub
}

func NewMarkerHandler(s *service.MarkerService, hub *wshub.Hub) *MarkerHandler {
	return &MarkerHandler{svc: s, hub: hub}
}

type markerDTO struct {
	ID         string     `json:"id"`
	GameID     string     `json:"game_id"`
	AuthorID   string     `json:"author_id"`
	Kind       string     `json:"kind"`
	Visibility string     `json:"visibility"`
	SideID     *string    `json:"side_id,omitempty"`
	SquadID    *string    `json:"squad_id,omitempty"`
	Lng        float64    `json:"lng"`
	Lat        float64    `json:"lat"`
	Label      *string    `json:"label,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	ExpiresAt  *time.Time `json:"expires_at,omitempty"`
}

func toDTO(m *model.Marker) markerDTO {
	return markerDTO{
		ID:         m.ID,
		GameID:     m.GameID,
		AuthorID:   m.AuthorID,
		Kind:       m.Kind,
		Visibility: string(m.Visibility),
		SideID:     m.SideID,
		SquadID:    m.SquadID,
		Lng:        m.Lng,
		Lat:        m.Lat,
		Label:      m.Label,
		CreatedAt:  m.CreatedAt,
		ExpiresAt:  m.ExpiresAt,
	}
}

type createMarkerRequest struct {
	Kind       string     `json:"kind"        binding:"required,min=1,max=32"`
	Visibility string     `json:"visibility"  binding:"required,oneof=self squad side organizers all"`
	Lng        float64    `json:"lng"         binding:"required"`
	Lat        float64    `json:"lat"         binding:"required"`
	Label      *string    `json:"label,omitempty"`
	ExpiresAt  *time.Time `json:"expires_at,omitempty"`
}

func (h *MarkerHandler) Create(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	var req createMarkerRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	m, err := h.svc.Create(c.Request.Context(), service.CreateMarkerInput{
		UserID:     userID,
		GameID:     gameID,
		Kind:       req.Kind,
		Visibility: model.Visibility(req.Visibility),
		Lng:        req.Lng,
		Lat:        req.Lat,
		Label:      req.Label,
		ExpiresAt:  req.ExpiresAt,
	})
	if err != nil {
		switch {
		case errors.Is(err, service.ErrForbidden):
			c.JSON(http.StatusForbidden, gin.H{"error": "no permission"})
		case errors.Is(err, service.ErrValidation):
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		}
		return
	}

	// Broadcast в WS — фильтр CanSee применит хаб (он держит MarkerService).
	if h.hub != nil {
		payload, _ := json.Marshal(m)
		h.hub.Broadcast(wshub.Packet{
			Type:    "marker",
			Author:  userID,
			GameID:  gameID,
			Payload: payload,
		})
	}

	c.JSON(http.StatusCreated, toDTO(m))
}

func (h *MarkerHandler) List(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	markers, err := h.svc.List(c.Request.Context(), userID, gameID)
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
	out := make([]markerDTO, 0, len(markers))
	for i := range markers {
		out = append(out, toDTO(&markers[i]))
	}
	c.JSON(http.StatusOK, gin.H{"markers": out})
}
