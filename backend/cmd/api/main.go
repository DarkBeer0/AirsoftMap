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
	sidesRepo := repository.NewSidesRepo(db)
	squadsRepo := repository.NewSquadsRepo(db)
	membersRepo := repository.NewMembersRepo(db)
	markersRepo := repository.NewMarkersRepo(db)
	eventsRepo := repository.NewEventsRepo(db)
	spawnsRepo := repository.NewSpawnPointsRepo(db)

	// Services
	gameSvc := service.NewGameService(gamesRepo, sidesRepo, squadsRepo, membersRepo, spawnsRepo)
	markerSvc := service.NewMarkerService(markersRepo, membersRepo, gamesRepo, squadsRepo)
	eventSvc := service.NewEventService(eventsRepo, membersRepo, gamesRepo)

	// WS hub. markerSvc передаётся как фильтр видимости (плагин-интерфейс,
	// чтобы хаб не тянул весь service-пакет).
	hub := wshub.NewHub(membersRepo, markerSvc)
	go hub.Run()

	// Handlers
	gameH := handler.NewGameHandler(gameSvc)
	sideH := handler.NewSideHandler(gameSvc)
	squadH := handler.NewSquadHandler(gameSvc)
	memberH := handler.NewMemberHandler(gameSvc, hub)
	markerH := handler.NewMarkerHandler(markerSvc, hub)
	spawnH := handler.NewSpawnHandler(gameSvc)
	eventH := handler.NewEventHandler(eventSvc, hub)
	wsH := handler.NewWsHandler(hub)

	// Router
	r := gin.Default()
	r.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})

	api := r.Group("/api/v1")

	// Join — защищённый, даже если игрок входит впервые. Supabase anonymous-сессия
	// выдаст JWT → у нас стабильный user_id, чтобы re-join после потери связи не
	// плодил дубли в game_members.
	auth := middleware.JWTAuth(jwtSecret, jwksURL)
	priv := api.Group("", auth)
	{
		priv.POST("/games", gameH.Create)
		priv.POST("/games/join", gameH.Join)
		priv.PATCH("/games/:id", gameH.Update)
		priv.POST("/games/:id/map-pack", gameH.SetMapPack)
		priv.POST("/games/:id/qr", gameH.GenerateQR)
		priv.GET("/games/:id/sides", sideH.List)
		priv.GET("/games/:id/squads", squadH.List)
		priv.POST("/games/:id/squads", squadH.Create)
		priv.GET("/games/:id/members", memberH.List)
		priv.PATCH("/games/:id/members/:uid", memberH.Update)
		priv.POST("/games/:id/markers", markerH.Create)
		priv.GET("/games/:id/markers", markerH.List)
		priv.POST("/games/:id/spawn-points", spawnH.Create)
		priv.GET("/games/:id/spawn-points", spawnH.List)
		priv.POST("/games/:id/kills", eventH.Kill)
		priv.POST("/games/:id/respawn", eventH.Respawn)
		priv.POST("/games/:id/events/sync", eventH.Sync)
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
