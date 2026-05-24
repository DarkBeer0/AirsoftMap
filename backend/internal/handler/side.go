package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/middleware"
	"github.com/airsoftmap/backend/internal/service"
)

type SideHandler struct {
	svc *service.GameService
}

func NewSideHandler(s *service.GameService) *SideHandler { return &SideHandler{svc: s} }

type sideListItemDTO struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Color    string  `json:"color"`
	JoinCode *string `json:"join_code,omitempty"`
}

func (h *SideHandler) List(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	sides, err := h.svc.ListSides(c.Request.Context(), userID, gameID)
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
	out := make([]sideListItemDTO, 0, len(sides))
	for _, s := range sides {
		out = append(out, sideListItemDTO{
			ID: s.ID, Name: s.Name, Color: s.Color, JoinCode: s.JoinCode,
		})
	}
	c.JSON(http.StatusOK, gin.H{"sides": out})
}
