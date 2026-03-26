package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	BytegraderURL    string
	BytegraderAPIKey string
	ResendAPIKey     string
	ResendFrom       string
	ClientPort       string
	PassingScore     float64
	CourseBURL       string
	AllowedOrigins   []string
	Coupons          map[string]string // assignment ID -> coupon code
}

func loadConfig() (*Config, error) {
	cfg := &Config{}
	var missing []string

	required := func(key string) string {
		v := os.Getenv(key)
		if v == "" {
			missing = append(missing, key)
		}
		return v
	}

	cfg.BytegraderURL = required("BYTEGRADER_URL")
	cfg.BytegraderAPIKey = required("BYTEGRADER_API_KEY")
	cfg.ResendAPIKey = required("RESEND_API_KEY")
	cfg.ResendFrom = required("RESEND_FROM")
	cfg.CourseBURL = required("COURSE_B_URL")

	if len(missing) > 0 {
		return nil, fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}

	cfg.ClientPort = os.Getenv("CLIENT_PORT")
	if cfg.ClientPort == "" {
		cfg.ClientPort = "8081"
	}

	passingScore := os.Getenv("PASSING_SCORE")
	if passingScore == "" {
		cfg.PassingScore = 80.0
	} else {
		v, err := strconv.ParseFloat(passingScore, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid PASSING_SCORE %q: %w", passingScore, err)
		}
		cfg.PassingScore = v
	}

	if origins := os.Getenv("ALLOWED_ORIGINS"); origins != "" {
		cfg.AllowedOrigins = strings.Split(origins, ",")
	}

	cfg.Coupons = make(map[string]string)
	for _, env := range os.Environ() {
		if !strings.HasPrefix(env, "COUPONS_") {
			continue
		}
		parts := strings.SplitN(env, "=", 2)
		if len(parts) != 2 || parts[1] == "" {
			continue
		}
		assignmentID := strings.TrimPrefix(parts[0], "COUPONS_")
		cfg.Coupons[assignmentID] = parts[1]
	}

	return cfg, nil
}
