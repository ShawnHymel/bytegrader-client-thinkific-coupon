package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"path/filepath"
	"time"
)

// bgClient is an HTTP client for the ByteGrader API.
type bgClient struct {
	baseURL    string
	apiKey     string
	httpClient *http.Client
}

func newBGClient(baseURL, apiKey string) *bgClient {
	return &bgClient{
		baseURL:    baseURL,
		apiKey:     apiKey,
		httpClient: &http.Client{Timeout: 30 * time.Second},
	}
}

// JobStatus is a flattened job result returned to the browser.
type JobStatus struct {
	Status   string  `json:"status"`
	Score    float64 `json:"score,omitempty"`
	Feedback string  `json:"feedback,omitempty"`
}

// bgSubmitResponse mirrors ByteGrader's POST /submit response.
type bgSubmitResponse struct {
	JobID string `json:"job_id"`
}

// bgStatusResponse mirrors ByteGrader's GET /status/{id} response.
type bgStatusResponse struct {
	Job struct {
		Status string `json:"status"`
		Result struct {
			Score    float64 `json:"score"`
			Feedback string  `json:"feedback"`
			Error    string  `json:"error"`
		} `json:"result"`
	} `json:"job"`
}

// Submit forwards a ZIP file to ByteGrader and returns the job ID.
// username is passed as X-Username for per-student rate limiting.
func (c *bgClient) Submit(assignmentID, username string, file io.Reader, filename string) (string, error) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)

	part, err := mw.CreateFormFile("file", filepath.Base(filename))
	if err != nil {
		return "", fmt.Errorf("create form file: %w", err)
	}
	if _, err := io.Copy(part, file); err != nil {
		return "", fmt.Errorf("copy file data: %w", err)
	}
	mw.Close()

	url := fmt.Sprintf("%s/submit?assignment=%s", c.baseURL, assignmentID)
	req, err := http.NewRequest(http.MethodPost, url, &buf)
	if err != nil {
		return "", fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("X-API-Key", c.apiKey)
	if username != "" {
		req.Header.Set("X-Username", username)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		var e struct{ Error string `json:"error"` }
		if json.Unmarshal(body, &e) == nil && e.Error != "" {
			return "", fmt.Errorf("%s", e.Error)
		}
		return "", fmt.Errorf("bytegrader returned %d", resp.StatusCode)
	}

	var result bgSubmitResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("parse response: %w", err)
	}
	if result.JobID == "" {
		return "", fmt.Errorf("empty job_id in response")
	}
	return result.JobID, nil
}

// GetStatus returns the current status of a ByteGrader job.
func (c *bgClient) GetStatus(jobID string) (*JobStatus, error) {
	url := fmt.Sprintf("%s/status/%s", c.baseURL, jobID)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("X-API-Key", c.apiKey)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		var e struct{ Error string `json:"error"` }
		if json.Unmarshal(body, &e) == nil && e.Error != "" {
			return nil, fmt.Errorf("%s", e.Error)
		}
		return nil, fmt.Errorf("bytegrader returned %d", resp.StatusCode)
	}

	var result bgStatusResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}

	status := &JobStatus{
		Status:   result.Job.Status,
		Score:    result.Job.Result.Score,
		Feedback: result.Job.Result.Feedback,
	}
	// Prefer the grader error message as feedback if feedback is empty
	if status.Feedback == "" && result.Job.Result.Error != "" {
		status.Feedback = result.Job.Result.Error
	}
	return status, nil
}
