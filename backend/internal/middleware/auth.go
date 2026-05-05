package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

const ContextUserID = "user_id"

// JWTAuth валидирует Supabase access-token.
//
// MVP: HS256 через shared secret (SUPABASE_JWT_SECRET).
// TODO: переключить на ES256 + JWKS (TurfStep уже умеет, портировать оттуда).
func JWTAuth(secret, jwksURL string) gin.HandlerFunc {
	return func(c *gin.Context) {
		authHdr := c.GetHeader("Authorization")
		// Для WS токен может прийти query-параметром
		if authHdr == "" {
			if t := c.Query("token"); t != "" {
				authHdr = "Bearer " + t
			}
		}
		if !strings.HasPrefix(authHdr, "Bearer ") {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing bearer"})
			return
		}
		raw := strings.TrimPrefix(authHdr, "Bearer ")

		token, err := jwt.Parse(raw, func(t *jwt.Token) (interface{}, error) {
			if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
				return nil, jwt.ErrTokenSignatureInvalid
			}
			return []byte(secret), nil
		})
		if err != nil || !token.Valid {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
			return
		}
		claims, ok := token.Claims.(jwt.MapClaims)
		if !ok {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "bad claims"})
			return
		}
		sub, _ := claims["sub"].(string)
		if sub == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "no sub"})
			return
		}
		c.Set(ContextUserID, sub)
		c.Next()
	}
}

func UserID(c *gin.Context) string {
	v, _ := c.Get(ContextUserID)
	s, _ := v.(string)
	return s
}
