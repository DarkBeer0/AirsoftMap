package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/middleware"
	"github.com/airsoftmap/backend/internal/service"
)

type SquadHandler struct {
	svc *service.GameService
}

func NewSquadHandler(s *service.GameService) *SquadHandler { return &SquadHandler{svc: s} }

type squadDTO struct {
	ID     string `json:"id"`
	SideID string `json:"side_id"`
	Name   string `json:"name"`
}

type createSquadRequest struct {
	SideID string `json:"side_id" binding:"required,uuid"`
	Name   string `json:"name"    binding:"required,min=1,max=40"`
}

func (h *SquadHandler) Create(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	var req createSquadRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	sq, err := h.svc.CreateSquad(c.Request.Context(), service.CreateSquadInput{
		UserID: userID,
		GameID: gameID,
		SideID: req.SideID,
		Name:   req.Name,
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
	c.JSON(http.StatusCreated, squadDTO{ID: sq.ID, SideID: sq.SideID, Name: sq.Name})
}

func (h *SquadHandler) List(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	squads, err := h.svc.ListSquads(c.Request.Context(), userID, gameID)
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
	out := make([]squadDTO, 0, len(squads))
	for _, s := range squads {
		out = append(out, squadDTO{ID: s.ID, SideID: s.SideID, Name: s.Name})
	}
	c.JSON(http.StatusOK, gin.H{"squads": out})
}
