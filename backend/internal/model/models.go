package model

import "time"

type GameStatus string

const (
	GameStatusLobby  GameStatus = "lobby"
	GameStatusActive GameStatus = "active"
	GameStatusEnded  GameStatus = "ended"
)

type Role string

const (
	RoleOrganizer      Role = "organizer"
	RoleSideCommander  Role = "side_commander"
	RoleSquadLeader    Role = "squad_leader"
	RoleSoldier        Role = "soldier"
)

type MemberStatus string

const (
	MemberStatusAlive      MemberStatus = "alive"
	MemberStatusDead       MemberStatus = "dead"
	MemberStatusRespawning MemberStatus = "respawning"
)

type Visibility string

const (
	VisibilitySelf       Visibility = "self"
	VisibilitySquad      Visibility = "squad"
	VisibilitySide       Visibility = "side"
	VisibilityOrganizers Visibility = "organizers"
	VisibilityAll        Visibility = "all"
)

type Game struct {
	ID          string     `db:"id"          json:"id"`
	OrganizerID string     `db:"organizer_id" json:"organizer_id"`
	Name        string     `db:"name"        json:"name"`
	JoinCode    string     `db:"join_code"   json:"join_code"`
	BboxMinLng  *float64   `db:"bbox_min_lng" json:"bbox_min_lng,omitempty"`
	BboxMinLat  *float64   `db:"bbox_min_lat" json:"bbox_min_lat,omitempty"`
	BboxMaxLng  *float64   `db:"bbox_max_lng" json:"bbox_max_lng,omitempty"`
	BboxMaxLat  *float64   `db:"bbox_max_lat" json:"bbox_max_lat,omitempty"`
	MapPackURL  *string    `db:"map_pack_url" json:"map_pack_url,omitempty"`
	Status      GameStatus `db:"status"       json:"status"`
	CreatedAt   time.Time  `db:"created_at"   json:"created_at"`
}

type Side struct {
	ID       string  `db:"id"        json:"id"`
	GameID   string  `db:"game_id"   json:"game_id"`
	Name     string  `db:"name"      json:"name"`
	Color    string  `db:"color"     json:"color"`
	JoinCode *string `db:"join_code" json:"join_code,omitempty"`
}

type Squad struct {
	ID     string `db:"id"      json:"id"`
	SideID string `db:"side_id" json:"side_id"`
	Name   string `db:"name"    json:"name"`
}

type SpawnPoint struct {
	ID     string  `db:"id"      json:"id"`
	GameID string  `db:"game_id" json:"game_id"`
	SideID *string `db:"side_id" json:"side_id,omitempty"`
	Name   string  `db:"name"    json:"name"`
	Lng    float64 `db:"lng"     json:"lng"`
	Lat    float64 `db:"lat"     json:"lat"`
	IsBase bool    `db:"is_base" json:"is_base"`
}

type GameMember struct {
	ID            string       `db:"id"             json:"id"`
	GameID        string       `db:"game_id"        json:"game_id"`
	UserID        string       `db:"user_id"        json:"user_id"`
	SideID        *string      `db:"side_id"        json:"side_id,omitempty"`
	SquadID       *string      `db:"squad_id"       json:"squad_id,omitempty"`
	Callsign      string       `db:"callsign"       json:"callsign"`
	Role          Role         `db:"role"           json:"role"`
	Status        MemberStatus `db:"status"         json:"status"`
	RespawnUntil  *time.Time   `db:"respawn_until"  json:"respawn_until,omitempty"`
	LastLng       *float64     `db:"last_lng"       json:"last_lng,omitempty"`
	LastLat       *float64     `db:"last_lat"       json:"last_lat,omitempty"`
	LastUpdate    *time.Time   `db:"last_update"    json:"last_update,omitempty"`
}

type Marker struct {
	ID         string     `db:"id"          json:"id"`
	GameID     string     `db:"game_id"     json:"game_id"`
	AuthorID   string     `db:"author_id"   json:"author_id"`
	Kind       string     `db:"kind"        json:"kind"`
	Visibility Visibility `db:"visibility"  json:"visibility"`
	SideID     *string    `db:"side_id"     json:"side_id,omitempty"`
	SquadID    *string    `db:"squad_id"    json:"squad_id,omitempty"`
	Lng        float64    `db:"lng"         json:"lng"`
	Lat        float64    `db:"lat"         json:"lat"`
	Label      *string    `db:"label"       json:"label,omitempty"`
	CreatedAt  time.Time  `db:"created_at"  json:"created_at"`
	ExpiresAt  *time.Time `db:"expires_at"  json:"expires_at,omitempty"`
}

type Event struct {
	ID         string    `db:"id"          json:"id"`
	GameID     string    `db:"game_id"     json:"game_id"`
	UserID     string    `db:"user_id"     json:"user_id"`
	Type       string    `db:"type"        json:"type"`
	Payload    *string   `db:"payload"     json:"payload,omitempty"`
	OccurredAt time.Time `db:"occurred_at" json:"occurred_at"`
	ReceivedAt time.Time `db:"received_at" json:"received_at"`
}
