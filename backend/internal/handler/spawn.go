package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/middleware"
	"github.com/airsoftmap/backend/internal/service"
)

type SpawnHandler struct {
	svc *service.GameService
}

func NewSpawnHandler(s *service.GameService) *SpawnHandler { return &SpawnHandler{svc: s} }

type spawnDTO struct {
	ID     string  `json:"id"`
	GameID string  `json:"game_id"`
	SideID *string `json:"side_id,omitempty"`
	Name   string  `json:"name"`
	Lng    float64 `json:"lng"`
	Lat    float64 `json:"lat"`
	IsBase bool    `json:"is_base"`
}

type createSpawnRequest struct {
	SideID *string `json:"side_id,omitempty"`
	Name   string  `json:"name"        binding:"required,min=1,max=40"`
	Lng    float64 `json:"lng"         binding:"required"`
	Lat    float64 `json:"lat"         binding:"required"`
	IsBase bool    `json:"is_base"`
}

func (h *SpawnHandler) Create(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	var req createSpawnRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	sp, err := h.svc.CreateSpawnPoint(c.Request.Context(), service.CreateSpawnPointInput{
		UserID: userID,
		GameID: gameID,
		SideID: req.SideID,
		Name:   req.Name,
		Lng:    req.Lng,
		Lat:    req.Lat,
		IsBase: req.IsBase,
	})
	if err != nil {
		switch {
		case errors.Is(err, service.ErrForbidden):
			c.JSON(http.StatusForbidden, gin.H{"error": "only organizer can place spawn"})
		case errors.Is(err, service.ErrValidation):
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		}
		return
	}
	c.JSON(http.StatusCreated, spawnDTO{
		ID:     sp.ID,
		GameID: sp.GameID,
		SideID: sp.SideID,
		Name:   sp.Name,
		Lng:    sp.Lng,
		Lat:    sp.Lat,
		IsBase: sp.IsBase,
	})
}

func (h *SpawnHandler) List(c *gin.Context) {
	gameID := c.Param("id")
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	spawns, err := h.svc.ListSpawnPoints(c.Request.Context(), userID, gameID)
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
	out := make([]spawnDTO, 0, len(spawns))
	for _, s := range spawns {
		out = append(out, spawnDTO{
			ID: s.ID, GameID: s.GameID, SideID: s.SideID,
			Name: s.Name, Lng: s.Lng, Lat: s.Lat, IsBase: s.IsBase,
		})
	}
	c.JSON(http.StatusOK, gin.H{"spawn_points": out})
}
