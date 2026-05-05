package handler

import (
	"net/http"

	"github.com/coder/websocket"
	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/middleware"
	wshub "github.com/airsoftmap/backend/internal/websocket"
)

type WsHandler struct {
	hub *wshub.Hub
}

func NewWsHandler(h *wshub.Hub) *WsHandler { return &WsHandler{hub: h} }

func (h *WsHandler) Connect(c *gin.Context) {
	gameID := c.Query("game")
	if gameID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "game required"})
		return
	}
	userID := middleware.UserID(c)

	conn, err := websocket.Accept(c.Writer, c.Request, &websocket.AcceptOptions{
		InsecureSkipVerify: true, // CORS нет, всё равно идёт через мобильник
	})
	if err != nil {
		return
	}

	h.hub.Serve(c.Request.Context(), conn, userID, gameID)
}
