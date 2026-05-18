package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/middleware"
	"github.com/airsoftmap/backend/internal/service"
)

type MemberHandler struct {
	svc *service.GameService
}

func NewMemberHandler(s *service.GameService) *MemberHandler { return &MemberHandler{svc: s} }

type memberDTO struct {
	ID       string   `json:"id"`
	UserID   string   `json:"user_id"`
	SideID   *string  `json:"side_id,omitempty"`
	SquadID  *string  `json:"squad_id,omitempty"`
	Callsign string   `json:"callsign"`
	Role     string   `json:"role"`
	Status   string   `json:"status"`
	LastLng  *float64 `json:"last_lng,omitempty"`
	LastLat  *float64 `json:"last_lat,omitempty"`
}

type listMembersResponse struct {
	Members []memberDTO `json:"members"`
}

func (h *MemberHandler) List(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}

	members, err := h.svc.ListMembers(c.Request.Context(), userID, gameID)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrForbidden):
			c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this game"})
		case errors.Is(err, service.ErrGameNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "game not found"})
		case errors.Is(err, service.ErrValidation):
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		}
		return
	}

	out := make([]memberDTO, 0, len(members))
	for _, m := range members {
		out = append(out, memberDTO{
			ID:       m.ID,
			UserID:   m.UserID,
			SideID:   m.SideID,
			SquadID:  m.SquadID,
			Callsign: m.Callsign,
			Role:     string(m.Role),
			Status:   string(m.Status),
			LastLng:  m.LastLng,
			LastLat:  m.LastLat,
		})
	}
	c.JSON(http.StatusOK, listMembersResponse{Members: out})
}

func (h *MemberHandler) Update(c *gin.Context) {
	// TODO (фаза 2): PATCH назначение отряда / роли. Только organizer / side_commander.
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "patch member"})
}
