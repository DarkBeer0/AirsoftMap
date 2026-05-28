package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/middleware"
	"github.com/airsoftmap/backend/internal/service"
)

type GameHandler struct {
	svc *service.GameService
}

func NewGameHandler(s *service.GameService) *GameHandler { return &GameHandler{svc: s} }

// --- Create ---

type createGameSideDTO struct {
	Name  string `json:"name"  binding:"required,min=1,max=40"`
	Color string `json:"color" binding:"required,min=1,max=20"`
}

type createGameRequest struct {
	Name           string              `json:"name"  binding:"required,min=1,max=80"`
	Sides          []createGameSideDTO `json:"sides" binding:"required,min=1,max=8,dive"`
	BboxMinLng     *float64            `json:"bbox_min_lng,omitempty"`
	BboxMinLat     *float64            `json:"bbox_min_lat,omitempty"`
	BboxMaxLng     *float64            `json:"bbox_max_lng,omitempty"`
	BboxMaxLat     *float64            `json:"bbox_max_lat,omitempty"`
	RespawnSeconds int                 `json:"respawn_seconds,omitempty" binding:"omitempty,min=10,max=900"`
}

type sideDTO struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Color    string  `json:"color"`
	JoinCode *string `json:"join_code,omitempty"`
}

type createGameResponse struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	JoinCode       string    `json:"join_code"`
	Status         string    `json:"status"`
	RespawnSeconds int       `json:"respawn_seconds"`
	Sides          []sideDTO `json:"sides"`
}

func (h *GameHandler) Create(c *gin.Context) {
	var req createGameRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}

	sides := make([]service.SideInput, 0, len(req.Sides))
	for _, s := range req.Sides {
		sides = append(sides, service.SideInput{Name: s.Name, Color: s.Color})
	}

	res, err := h.svc.Create(c.Request.Context(), service.CreateGameInput{
		Name:           req.Name,
		OrganizerID:    userID,
		Sides:          sides,
		BboxMinLng:     req.BboxMinLng,
		BboxMinLat:     req.BboxMinLat,
		BboxMaxLng:     req.BboxMaxLng,
		BboxMaxLat:     req.BboxMaxLat,
		RespawnSeconds: req.RespawnSeconds,
	})
	if err != nil {
		if errors.Is(err, service.ErrValidation) {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	resp := createGameResponse{
		ID:             res.Game.ID,
		Name:           res.Game.Name,
		JoinCode:       res.Game.JoinCode,
		Status:         string(res.Game.Status),
		RespawnSeconds: res.Game.RespawnSeconds,
		Sides:          make([]sideDTO, 0, len(res.Sides)),
	}
	for _, s := range res.Sides {
		resp.Sides = append(resp.Sides, sideDTO{
			ID: s.ID, Name: s.Name, Color: s.Color, JoinCode: s.JoinCode,
		})
	}
	c.JSON(http.StatusCreated, resp)
}

// --- Join ---

type joinRequest struct {
	SideJoinCode string `json:"side_join_code" binding:"required,min=3,max=12"`
	Callsign     string `json:"callsign,omitempty"`
}

type joinResponse struct {
	GameID         string  `json:"game_id"`
	GameName       string  `json:"game_name"`
	SideID         string  `json:"side_id"`
	SideName       string  `json:"side_name"`
	SideColor      string  `json:"side_color"`
	Callsign       string  `json:"callsign"`
	Role           string  `json:"role"`
	RespawnSeconds int     `json:"respawn_seconds"`
	MapPackURL     *string `json:"map_pack_url,omitempty"`
}

func (h *GameHandler) Join(c *gin.Context) {
	var req joinRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}

	res, err := h.svc.JoinBySideCode(c.Request.Context(), userID, req.SideJoinCode, req.Callsign)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrInvalidJoinCode):
			c.JSON(http.StatusNotFound, gin.H{"error": "invalid join code"})
		case errors.Is(err, service.ErrGameNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "game not found"})
		case errors.Is(err, service.ErrValidation):
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		}
		return
	}

	c.JSON(http.StatusOK, joinResponse{
		GameID:         res.Game.ID,
		GameName:       res.Game.Name,
		SideID:         res.Side.ID,
		SideName:       res.Side.Name,
		SideColor:      res.Side.Color,
		Callsign:       res.Member.Callsign,
		Role:           string(res.Member.Role),
		RespawnSeconds: res.Game.RespawnSeconds,
		MapPackURL:     res.Game.MapPackURL,
	})
}

// --- Заглушки (фаза 2) ---

func (h *GameHandler) Update(c *gin.Context) {
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "update game"})
}

type setMapPackRequest struct {
	MapPackURL string   `json:"map_pack_url" binding:"required,url"`
	BboxMinLng *float64 `json:"bbox_min_lng,omitempty"`
	BboxMinLat *float64 `json:"bbox_min_lat,omitempty"`
	BboxMaxLng *float64 `json:"bbox_max_lng,omitempty"`
	BboxMaxLat *float64 `json:"bbox_max_lat,omitempty"`
}

func (h *GameHandler) SetMapPack(c *gin.Context) {
	gameID := c.Param("id")
	var req setMapPackRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	userID := middleware.UserID(c)
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "no user"})
		return
	}
	err := h.svc.SetMapPack(c.Request.Context(), service.SetMapPackInput{
		UserID:     userID,
		GameID:     gameID,
		MapPackURL: req.MapPackURL,
		BboxMinLng: req.BboxMinLng,
		BboxMinLat: req.BboxMinLat,
		BboxMaxLng: req.BboxMaxLng,
		BboxMaxLat: req.BboxMaxLat,
	})
	if err != nil {
		switch {
		case errors.Is(err, service.ErrForbidden):
			c.JSON(http.StatusForbidden, gin.H{"error": "only organizer can set map pack"})
		case errors.Is(err, service.ErrValidation):
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		}
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *GameHandler) GenerateQR(c *gin.Context) {
	// QR рендерится на клиенте, сервер просто отдаёт join_code (он уже в createGameResponse / joinResponse).
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "generate qr"})
}
