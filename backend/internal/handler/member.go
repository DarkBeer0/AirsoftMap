package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/airsoftmap/backend/internal/service"
)

type MemberHandler struct {
	svc *service.GameService
}

func NewMemberHandler(s *service.GameService) *MemberHandler { return &MemberHandler{svc: s} }

func (h *MemberHandler) List(c *gin.Context) {
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "list members"})
}

func (h *MemberHandler) Update(c *gin.Context) {
	// PATCH назначение отряда / роли. Только организатор / командир стороны.
	c.JSON(http.StatusNotImplemented, gin.H{"todo": "patch member"})
}
