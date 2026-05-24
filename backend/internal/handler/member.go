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

type updateMemberRequest struct {
	SideID   *string `json:"side_id,omitempty"`
	SquadID  *string `json:"squad_id,omitempty"`
	Role     *string `json:"role,omitempty"`     // organizer | side_commander | squad_leader | soldier
	Callsign *string `json:"callsign,omitempty"`
}

func (h *MemberHandler) Update(c *gin.Context) {
	gameID := c.Param("id")
	memberID := c.Param("uid")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	var req updateMemberRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	// Пустые строки в squad/side трактуем как «снять назначение» (NULL).
	// Сейчас COALESCE в repo не различает «не передано» и «явный NULL» —
	// поэтому пустую строку чистим до nil → ничего не меняем.
	// TODO (фаза 3): отдельная JSON-семантика null для unset.
	normalizeEmpty(&req.SideID)
	normalizeEmpty(&req.SquadID)
	normalizeEmpty(&req.Role)
	normalizeEmpty(&req.Callsign)

	updated, err := h.svc.UpdateMember(c.Request.Context(), service.UpdateMemberInput{
		CallerID: userID,
		GameID:   gameID,
		MemberID: memberID,
		SideID:   req.SideID,
		SquadID:  req.SquadID,
		Role:     req.Role,
		Callsign: req.Callsign,
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
	c.JSON(http.StatusOK, memberDTO{
		ID:       updated.ID,
		UserID:   updated.UserID,
		SideID:   updated.SideID,
		SquadID:  updated.SquadID,
		Callsign: updated.Callsign,
		Role:     string(updated.Role),
		Status:   string(updated.Status),
		LastLng:  updated.LastLng,
		LastLat:  updated.LastLat,
	})
}

func normalizeEmpty(s **string) {
	if *s != nil && **s == "" {
		*s = nil
	}
}
