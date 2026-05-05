package main

import (
	"log"
	"net/http"
	"os"

	"github.com/gin-gonic/gin"
	"github.com/jmoiron/sqlx"
	"github.com/joho/godotenv"
	_ "github.com/lib/pq"

	"github.com/airsoftmap/backend/internal/handler"
	"github.com/airsoftmap/backend/internal/middleware"
	"github.com/airsoftmap/backend/internal/repository"
	"github.com/airsoftmap/backend/internal/service"
	wshub "github.com/airsoftmap/backend/internal/websocket"
)

func main() {
	_ = godotenv.Load()

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Fatal("DATABASE_URL not set")
	}
	db, err := sqlx.Connect("postgres", dsn)
	if err != nil {
		log.Fatalf("db connect: %v", err)
	}
	defer db.Close()

	jwtSecret := os.Getenv("SUPABASE_JWT_SECRET")
	jwksURL := os.Getenv("SUPABASE_JWKS_URL") // опционально (ES256/JWKS)

	// Repos
	gamesRepo := repository.NewGamesRepo(db)
	membersRepo := repository.NewMembersRepo(db)
	markersRepo := repository.NewMarkersRepo(db)
	eventsRepo := repository.NewEventsRepo(db)

	// Services
	gameSvc := service.NewGameService(gamesRepo, membersRepo)
	markerSvc := service.NewMarkerService(markersRepo, membersRepo)
	eventSvc := service.NewEventService(eventsRepo, membersRepo)

	// WS hub
	hub := wshub.NewHub(membersRepo)
	go hub.Run()

	// Handlers
	gameH := handler.NewGameHandler(gameSvc)
	memberH := handler.NewMemberHandler(gameSvc)
	markerH := handler.NewMarkerHandler(markerSvc)
	eventH := handler.NewEventHandler(eventSvc)
	wsH := handler.NewWsHandler(hub)

	// Router
	r := gin.Default()
	r.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})

	api := r.Group("/api/v1")

	// Public
	api.POST("/games/join", gameH.Join)

	// Protected
	auth := middleware.JWTAuth(jwtSecret, jwksURL)
	priv := api.Group("", auth)
	{
		priv.POST("/games", gameH.Create)
		priv.PATCH("/games/:id", gameH.Update)
		priv.POST("/games/:id/map-pack", gameH.SetMapPack)
		priv.POST("/games/:id/qr", gameH.GenerateQR)
		priv.GET("/games/:id/members", memberH.List)
		priv.PATCH("/games/:id/members/:uid", memberH.Update)
		priv.POST("/games/:id/markers", markerH.Create)
		priv.GET("/games/:id/markers", markerH.List)
		priv.POST("/games/:id/kills", eventH.Kill)
		priv.POST("/games/:id/respawn", eventH.Respawn)
		priv.GET("/ws", wsH.Connect)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("AirsoftMap API listening on :%s", port)
	if err := r.Run(":" + port); err != nil {
		log.Fatal(err)
	}
}
