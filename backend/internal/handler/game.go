package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/service"
)

type GameHandler struct {
	svc *service.GameService
}

func NewGameHandler(s *service.GameService) *GameHandler { return &GameHandler{svc: s} }

func (h *GameHandler) Create(c *gin.Context) {
	// TODO: bind {name, bbox?, sides?}, создать игру + сторонами.
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "create game"})
}

func (h *GameHandler) Update(c *gin.Context) {
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "update game"})
}

func (h *GameHandler) Join(c *gin.Context) {
	// Публичный эндпоинт: {join_code} → {game_id, side_id, callsign, map_pack_url}
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "join game by code"})
}

func (h *GameHandler) SetMapPack(c *gin.Context) {
	// PATCH map_pack_url после загрузки .mbtiles в Supabase Storage.
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "set map pack"})
}

func (h *GameHandler) GenerateQR(c *gin.Context) {
	// Возвращает короткий код / deeplink (QR рендерится на клиенте).
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "generate qr"})
}
