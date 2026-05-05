package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/service"
)

type EventHandler struct {
	svc *service.EventService
}

func NewEventHandler(s *service.EventService) *EventHandler { return &EventHandler{svc: s} }

func (h *EventHandler) Kill(c *gin.Context) {
	// TODO: member→dead, записать event, WS broadcast (только своим / организатору).
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "kill"})
}

func (h *EventHandler) Respawn(c *gin.Context) {
	// TODO: member→alive (после таймера), record event.
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "respawn"})
}
