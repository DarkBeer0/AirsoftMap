package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/service"
)

type MarkerHandler struct {
	svc *service.MarkerService
}

func NewMarkerHandler(s *service.MarkerService) *MarkerHandler { return &MarkerHandler{svc: s} }

func (h *MarkerHandler) Create(c *gin.Context) {
	// TODO: создать метку, потом WS broadcast по правилам visibility.
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "create marker"})
}

func (h *MarkerHandler) List(c *gin.Context) {
	// TODO: фильтр на сервере по svc.CanSee для текущего user.
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "list markers"})
}
