// Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package lambda

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestClient_ListMaintenanceEvents_PaginatedResponse_ReturnsAllEvents(t *testing.T) {
	page1Token := "token-page2"
	page1 := apiResponse{
		Data: []Event{
			{ID: "event-1", Urgency: "emergency", Status: "scheduled"},
		},
		PageToken: &page1Token,
	}

	page2 := apiResponse{
		Data: []Event{
			{ID: "event-2", Urgency: "critical_with_deadline", Status: "scheduled"},
		},
		PageToken: nil,
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "Bearer test-key", r.Header.Get("Authorization"))

		var resp apiResponse
		if r.URL.Query().Get("page_token") == page1Token {
			resp = page2
		} else {
			resp = page1
		}

		w.Header().Set("Content-Type", "application/json")
		require.NoError(t, json.NewEncoder(w).Encode(resp))
	}))
	defer srv.Close()

	t.Setenv(APIKeyEnvVar, "test-key")

	client := NewClient(srv.URL, WithHTTPClient(srv.Client()))

	events, err := client.ListMaintenanceEvents(context.Background())
	require.NoError(t, err)
	require.Len(t, events, 2)
	assert.Equal(t, "event-1", events[0].ID)
	assert.Equal(t, "event-2", events[1].ID)
}

func TestClient_ListMaintenanceEvents_ServerError_ReturnsWrappedStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		fmt.Fprint(w, `{"error":"unauthorized"}`)
	}))
	defer srv.Close()

	t.Setenv(APIKeyEnvVar, "bad-key")

	client := NewClient(srv.URL, WithHTTPClient(srv.Client()))

	_, err := client.ListMaintenanceEvents(context.Background())
	assert.ErrorContains(t, err, "401")
}
